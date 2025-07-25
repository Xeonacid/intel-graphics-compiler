/*========================== begin_copyright_notice ============================

Copyright (C) 2021-2023 Intel Corporation

SPDX-License-Identifier: MIT

============================= end_copyright_notice ===========================*/

#include "vc/Driver/Driver.h"
#include "vc/Support/ShaderDump.h"
#include "vc/Support/Status.h"
#include "vc/igcdeps/cmc.h"

#include "lldWrapper/Common/Driver.h"

#include <llvm/Support/Debug.h>
#include <llvm/Support/FileUtilities.h>
#include <llvm/Support/ToolOutputFile.h>
#include <llvm/BinaryFormat/ELF.h>

using namespace vc;

struct DebugInfo {
  llvm::StringRef KernelName;
  llvm::StringRef DebugData;
};

// Implementation of CGen8CMProgram.
CGen8CMProgram::CGen8CMProgram(const CompileOptions &Opts, PLATFORM platform,
                               llvm::ArrayRef<char> SPIRV)
    : CGen8OpenCLProgramBase(platform),
      m_programInfo(new IGC::SOpenCLProgramInfo), m_opts(Opts), m_spirv(SPIRV) {
}

TmpFilesStorage
CGen8CMProgram::extractRawDebugInfo(llvm::raw_ostream &ErrStream) {
  std::vector<DebugInfo> DebugInfoData;
  std::transform(
      m_kernels.begin(), m_kernels.end(), std::back_inserter(DebugInfoData),
      [](const auto &Kernel) {
        llvm::StringRef KernelName = Kernel->m_kernelInfo.m_kernelName;
        const auto &KO = Kernel->getProgramOutput();
        if (!KO.m_debugData)
          return DebugInfo{KernelName, llvm::StringRef{}};
        const auto *RawData =
            reinterpret_cast<const char *>(KO.m_debugData);
        return DebugInfo{KernelName,
                         llvm::StringRef{RawData, KO.m_debugDataSize}};
      });
  IGC_ASSERT(DebugInfoData.size() == m_kernels.size());

  TmpFilesStorage Result;
  for (const auto &DebugInfo : DebugInfoData) {
    llvm::SmallString<128> TmpPath;
    int FD = -1;
    auto EC = llvm::sys::fs::createTemporaryFile("ze", "elf", FD, TmpPath);
    if (EC) {
      ErrStream << "could not create temporary file: " << EC.message() << "\n";
      return {};
    }
    addElfKernelMapping(TmpPath.c_str(), DebugInfo.KernelName.str());

    auto Out = std::make_unique<llvm::ToolOutputFile>(TmpPath, FD);
    Out->os() << DebugInfo.DebugData;
    Out->os().flush();

    auto Emplaced = Result.emplace(TmpPath.str(), std::move(Out));
    IGC_ASSERT_MESSAGE(Emplaced.second,
                       "could not create unique temporary storage");
  }
  IGC_ASSERT(DebugInfoData.size() == Result.size());
  return Result;
}

std::unique_ptr<llvm::MemoryBuffer> CGen8CMProgram::buildZeDebugInfo() {
  llvm::raw_string_ostream ErrStream{m_ErrorLog};
  auto TmpFiles = extractRawDebugInfo(ErrStream);
  if (TmpFiles.empty()) {
    ErrStream << "could not initialize linking of the debug information\n";
    return {};
  }

  llvm::SmallString<128> OutputPath;
  auto Errc =
      llvm::sys::fs::createTemporaryFile("final_dbginfo", "elf", OutputPath);
  if (Errc) {
    ErrStream << "could not create output file for the linked debug info: "
              << Errc.message() << "\n";
    return {};
  }

  std::vector<const char *> LldArgs;
  LldArgs.push_back("lld");
  std::transform(TmpFiles.begin(), TmpFiles.end(), std::back_inserter(LldArgs),
                 [](const auto &TmpFile) { return TmpFile.first.c_str(); });
  LldArgs.push_back("--relocatable");
  LldArgs.push_back("-o");
  LldArgs.push_back(OutputPath.c_str());

  if (IGC_IS_FLAG_ENABLED(VCEnableExtraDebugLogging)) {
    for (const auto *Arg : LldArgs)
      llvm::errs() << " " << Arg;
    llvm::errs() << "\n";
  }

  // Currently, DummyOutput/OutStream are not used outside of debugging purposes
  // (we don't have facilities to emit extra logs from binary building routines)
  std::string DummyOutput;
  llvm::raw_string_ostream OutStream(DummyOutput);
  constexpr bool CanExitEarly = false;
  if (!IGCLLD::elf::link(LldArgs, CanExitEarly, OutStream, ErrStream)) {
    ErrStream << "could not link debug infomation file\n";
    return {};
  }
  llvm::FileRemover Remover{OutputPath};

  if (IGC_IS_FLAG_ENABLED(VCEnableExtraDebugLogging)) {
    if (!OutStream.str().empty())
      llvm::errs() << "lld stdout:\n" << DummyOutput << "\n";
    else
      llvm::errs() << "lld has nothing on stdout (ok)\n";
  }

  auto Res = llvm::MemoryBuffer::getFile(OutputPath);
  if (!Res) {
    ErrStream << "could not read linked debug information file\n";
    return {};
  }
  if (Res.get()->getBufferSize() == 0) {
    ErrStream << "file with the linked debug information is empty\n";
    return {};
  }

  return std::move(Res.get());
}

llvm::Error CGen8CMProgram::GetError() const {
  IGC_ASSERT(HasErrors());
  return llvm::make_error<vc::OutputBinaryCreationError>(m_ErrorLog);
}

void CGen8CMProgram::GetZEBinary(llvm::raw_pwrite_stream &programBinary,
                                 unsigned pointerSizeInBytes) {
  // Contains buffer to an optional debug info. Should exists till zebuilder
  // is destroyed.
  std::unique_ptr<llvm::MemoryBuffer> DebugInfoHolder;

  const uint8_t *SpirvData = reinterpret_cast<const uint8_t *>(m_spirv.data());
  size_t SpirvSize = m_spirv.size();

  const auto &ApiOpts = m_opts.ApiOptions;
  const uint8_t *OptsData = reinterpret_cast<const uint8_t *>(ApiOpts.data());
  size_t OptsSize = ApiOpts.size();

  iOpenCL::ZEBinaryBuilder zebuilder(m_Platform, pointerSizeInBytes == 8,
                                     *m_programInfo, SpirvData, SpirvSize,
                                     nullptr, 0, OptsData, OptsSize);
  zebuilder.setGfxCoreFamily(m_Platform.eRenderCoreFamily);
  zebuilder.setGmdID(m_Platform.sRenderBlockID);

  for (const auto &kernel : m_kernels) {
    zebuilder.createKernel(
        reinterpret_cast<const char *>(kernel->getProgramOutput().m_programBin),
        kernel->getProgramOutput().m_programSize, kernel->m_kernelInfo, kernel->m_kernelCostExpInfo,
        kernel->m_GRFSizeInBytes,
        kernel->getProgramOutput().m_VISAAsm);
  }

  bool HasDebugInformation =
      std::any_of(m_kernels.begin(), m_kernels.end(),
                  [](const auto& kernel) {
                    return kernel->getProgramOutput().m_debugDataSize > 0;
                  });
  if (HasDebugInformation) {
    DebugInfoHolder = buildZeDebugInfo();
    if (DebugInfoHolder) {
      // Unfortunately, we do need const_cast here, since API requires void*
      void *BufferStart = const_cast<void *>(
          reinterpret_cast<const void *>(DebugInfoHolder->getBufferStart()));
      zebuilder.addElfSections(BufferStart, DebugInfoHolder->getBufferSize());
    }
  }
  dumpElfKernelMapFile();
  zebuilder.getBinaryObject(programBinary);

  if (IGC_IS_FLAG_ENABLED(ShaderDumpEnable))
    zebuilder.printZEInfo(m_opts.Dumper->composeDumpPath("", "zeinfo"));
}

bool CGen8CMProgram::HasCrossThreadOffsetRelocations() {
  for (const auto &kernel : m_kernels) {
    for (const auto &reloc : kernel->getProgramOutput().m_relocs) {
      if (reloc.r_symbol == vISA::CROSS_THREAD_OFF_R0_RELOCATION_NAME) {
        return true;
      }
    }
  }
  return false;
}

bool CGen8CMProgram::HasPerThreadOffsetRelocations() {
  for (const auto &kernel : m_kernels) {
    for (const auto &reloc : kernel->getProgramOutput().m_relocs) {
      if (reloc.r_symbol == vISA::PER_THREAD_OFF_RELOCATION_NAME) {
        return true;
      }
    }
  }
  return false;
}
