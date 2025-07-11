/*========================== begin_copyright_notice ============================

Copyright (C) 2019-2024 Intel Corporation

SPDX-License-Identifier: MIT

============================= end_copyright_notice ===========================*/

#pragma once

#include <string>
#include <type_traits>

#include <llvm/ADT/ArrayRef.h>
#include <llvm/Support/DynamicLibrary.h>

#include "Compiler/CodeGenPublic.h"

#include "vc/GenXCodeGen/GenXOCLRuntimeInfo.h"

#include "Probe/Assertion.h"
#include "common/VCPlatformSelector.hpp"

#include "AdaptorOCL/OCL/sp/spp_g8.h"

namespace llvm {
class Error;
class ToolOutputFile;
class raw_ostream;
} // namespace llvm

namespace vc {

struct CompileOptions;

// Interface to compile and package cm kernels into OpenCL binars.
class CMKernel {
  using KernelArgInfo = llvm::GenXOCLRuntimeInfo::KernelArgInfo;

public:
  using ArgKind = KernelArgInfo::KindType;
  using ArgAccessKind = KernelArgInfo::AccessKindType;
  using ArgAddressMode = KernelArgInfo::AddressModeType;

  explicit CMKernel(const PLATFORM &platform);
  ~CMKernel();
  CMKernel(const CMKernel &) = delete;
  CMKernel &operator=(const CMKernel &) = delete;

  PLATFORM m_platform;
  IGC::SOpenCLKernelInfo m_kernelInfo;
  IGC::SOpenCLKernelCostExpInfo m_kernelCostExpInfo;
  IGC::COCLBTILayout m_btiLayout;
  uint32_t m_GRFSizeInBytes = 0;

  // getter for convenience
  const IGC::SProgramOutput &getProgramOutput() const {
    IGC_ASSERT_MESSAGE(m_kernelInfo.m_executionEnvironment.CompiledSIMDSize ==
                           1,
                       "SIMD size is expected to be 1 for CMKernel");
    return m_kernelInfo.m_kernelProgram.simd1;
  }

  // getter for convenience
  IGC::SProgramOutput &getProgramOutput() {
    return const_cast<IGC::SProgramOutput &>(
        static_cast<const CMKernel *>(this)->getProgramOutput());
  }

  // General argument
  void createConstArgumentAnnotation(unsigned argNo, unsigned sizeInBytes,
                                     unsigned payloadPosition,
                                     unsigned offsetInArg);

  // 1D/2D/3D Surface
  void createImageAnnotation(const KernelArgInfo &ArgInfo, unsigned Offset);

  // Add pointer argument information to ZEInfo
  void createPointerGlobalAnnotation(const KernelArgInfo &ArgInfo,
                                     unsigned Offset);

  void createPointerLocalAnnotation(unsigned index, unsigned offset,
                                    unsigned sizeInBytes, unsigned alignment);

  void createPrivateBaseAnnotation(unsigned argNo, unsigned byteSize,
                                   unsigned payloadPosition, int BTI,
                                   unsigned statelessPrivateMemSize,
                                   bool isStateful);

  // Add stateful buffer information to ZEInfo
  void createBufferStatefulAnnotation(unsigned argNo, ArgAccessKind accessKind);

  // Local or global size
  void createSizeAnnotation(unsigned payloadPosition,
                            iOpenCL::DATA_PARAMETER_TOKEN type);

  // Global work offset/local work size
  void createImplicitArgumentsAnnotation(unsigned payloadPosition);

  // Sampler
  void createSamplerAnnotation(const KernelArgInfo &ArgInfo, unsigned Offset);

  void createAssertBufferArgAnnotation(unsigned Index, unsigned BTI,
                                       unsigned Size, unsigned ArgOffset);
  void createPrintfBufferArgAnnotation(unsigned Index, unsigned BTI,
                                       unsigned Size, unsigned ArgOffset);
  void createSyncBufferArgAnnotation(unsigned Index, unsigned BTI,
                                     unsigned Size, unsigned ArgOffset);

  void createImplArgsBufferAnnotation(unsigned Size, unsigned ArgOffset);

  void RecomputeBTLayout(int numUAVs, int numResources);
};

using ToolOutputHolder = std::unique_ptr<llvm::ToolOutputFile>;
using TmpFilesStorage = std::map<std::string, ToolOutputHolder>;

class CGen8CMProgram : public iOpenCL::CGen8OpenCLProgramBase {
public:
  explicit CGen8CMProgram(const CompileOptions &Opts, PLATFORM platform,
                          llvm::ArrayRef<char> SPIRV = {});

  void GetZEBinary(llvm::raw_pwrite_stream &programBinary,
                   unsigned pointerSizeInBytes) override;
  bool HasErrors() const { return !m_ErrorLog.empty(); };
  bool HasCrossThreadOffsetRelocations();
  bool HasPerThreadOffsetRelocations();
  llvm::Error GetError() const;

  // CM kernel list.
  using CMKernelsStorage = std::vector<std::unique_ptr<CMKernel>>;
  CMKernelsStorage m_kernels;

  // Data structure to create binaries.
  std::unique_ptr<IGC::SOpenCLProgramInfo> m_programInfo;

  std::string m_ErrorLog;

private:
  const CompileOptions &m_opts;
  const llvm::ArrayRef<char> m_spirv;

  TmpFilesStorage extractRawDebugInfo(llvm::raw_ostream &ErrStream);
  std::unique_ptr<llvm::MemoryBuffer> buildZeDebugInfo();
};

void createBinary(
    CGen8CMProgram &CMProgram,
    const llvm::GenXOCLRuntimeInfo::CompiledModuleT &CompiledModule);

} // namespace vc
