/*========================== begin_copyright_notice ============================

Copyright (C) 2023-2024 Intel Corporation

SPDX-License-Identifier: MIT

============================= end_copyright_notice ===========================*/

//
/// GenXSLMResolution
/// ---------------------------
///
/// GenXSLMResolution is a module pass which performs the following:
/// a. Lower llvm.genx.slm.init intrinsic.
/// b. Replace all SLM variables and the first SLM kernel argument uses
/// with offsets to SLM buffer.
///
/// To properly assign an offset to SLM variable the pass does the following:
/// 1. Build list of functions which are invoked from kernel by traversing
/// the call graph.
/// 2. Check which SLM variables have uses in functions from the function
/// group.
/// 3. Sort variables in alignment decline order and assign offsets to
/// them.
/// 4. Update total SLM size for a function group Head (kernel).
///
/// It is possible to avoid call graph traversing and simplify this pass by
/// making it a FunctionGroup pass. However, it will take away the opportunity
/// to run InstCombine after which is required to fold constants after SLM
/// variable uses replacing.
///
/// **IR Restriction** After this pass SLM size in kernel metadata should not be
/// updated anymore.
//
//===----------------------------------------------------------------------===//

#include "GenX.h"
#include "GenXTargetMachine.h"
#include "GenXUtil.h"

#include "vc/Support/GenXDiagnostic.h"
#include "vc/Utils/GenX/BreakConst.h"
#include "vc/Utils/GenX/GlobalVariable.h"
#include "vc/Utils/GenX/KernelInfo.h"
#include "vc/Utils/General/Types.h"

#include "llvmWrapper/Analysis/CallGraph.h"
#include "llvmWrapper/IR/Value.h"
#include "llvmWrapper/Support/Alignment.h"

#include <llvm/CodeGen/TargetPassConfig.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/InstIterator.h>
#include <llvm/IR/Module.h>
#include <llvm/InitializePasses.h>
#include <llvm/Pass.h>

using namespace llvm;

namespace {

class GenXSLMResolution : public ModulePass {
  CallGraph *CG = nullptr;
  const DataLayout *DL = nullptr;

public:
  static char ID;
  explicit GenXSLMResolution() : ModulePass(ID) {}
  StringRef getPassName() const override { return "GenX SLM Resolution"; }
  void getAnalysisUsage(AnalysisUsage &AU) const override {
    AU.addRequired<CallGraphWrapperPass>();
    AU.addRequired<TargetPassConfig>();
    AU.setPreservesCFG();
  }
  bool runOnModule(Module &M) override;

private:
  llvm::Align getGlobalVarAlign(const GlobalVariable &GV) const;
  Constant *allocateOnSLM(const GlobalVariable &GV, unsigned &SLMSize) const;
  Constant *getNextOffset(llvm::Align Alignment, LLVMContext &Ctx,
                          unsigned &SLMSize) const;
  void
  replaceSLMVariablesWithOffsets(SmallVectorImpl<GlobalVariable *> &Workload,
                                 SmallPtrSetImpl<Function *> &FunctionSet,
                                 unsigned &SLMSize) const;
  bool runForKernel(Function &Head, Module &M,
                    ArrayRef<GlobalVariable *> SLMVars);
};

} // end namespace

char GenXSLMResolution::ID = 0;
namespace llvm {
void initializeGenXSLMResolutionPass(PassRegistry &);
} // end namespace llvm

INITIALIZE_PASS_BEGIN(GenXSLMResolution, "GenXSLMResolution",
                      "GenXSLMResolution", false, false)
INITIALIZE_PASS_DEPENDENCY(CallGraphWrapperPass)
INITIALIZE_PASS_END(GenXSLMResolution, "GenXSLMResolution", "GenXSLMResolution",
                    false, false)

ModulePass *llvm::createGenXSLMResolution() {
  initializeGenXSLMResolutionPass(*PassRegistry::getPassRegistry());
  return new GenXSLMResolution;
}

static void lowerSlmInit(Instruction &I) {
  auto *BB = I.getParent();
  auto *F = BB->getParent();
  if (!vc::isKernel(F))
    vc::fatal(I.getContext(), "GenXSLMResolution",
              "SLM init call is supported only in kernels", &I);

  auto *V = dyn_cast<ConstantInt>(I.getOperand(0));
  if (!V)
    vc::fatal(I.getContext(), "GenXSLMResolution",
              "Cannot reserve non-constant amount of SLM", &I);

  unsigned SLMSize = V->getValue().getZExtValue();
  vc::KernelMetadata MD{F};
  if (SLMSize > MD.getSLMSize())
    MD.updateSLMSizeMD(SLMSize);
}

static bool isUserInList(const User &U,
                         const SmallPtrSetImpl<Function *> &FunctionSet) {
  auto *UserInst = dyn_cast<Instruction>(&U);
  if (!UserInst)
    return false;
  auto *F = UserInst->getFunction();
  return FunctionSet.count(F);
}

static bool isBelongToKernel(const GlobalVariable &GV,
                             const SmallPtrSetImpl<Function *> &FunctionSet) {
  return llvm::any_of(GV.users(), [&FunctionSet](const User *U) {
    return isUserInList(*U, FunctionSet);
  });
}

static SmallPtrSet<Function *, 8> traverseCallGraph(Function &Head,
                                                    CallGraph &CG) {
  SmallPtrSet<Function *, 8> Visited = {&Head};
  SmallVector<Function *, 8> Stack = {&Head};
  while (!Stack.empty()) {
    auto *F = Stack.pop_back_val();
    CallGraphNode &N = *CG[F];
    for (IGCLLVM::CallRecord CE : N) {
      auto *Child = CE.second->getFunction();
      if (!Child || Child->isDeclaration())
        continue;
      if (Visited.insert(Child).second)
        Stack.push_back(Child);
    }
  }
  return Visited;
}

static SmallVector<GlobalVariable *, 4> collectSLMVariables(Module &M) {
  SmallVector<GlobalVariable *, 4> SLMVars;
  for (auto &GV : M.globals()) {
    if ((GV.getAddressSpace() != vc::AddrSpace::Local) ||
        !vc::isRealGlobalVariable(GV))
      continue;
    if (!GV.hasLocalLinkage()) {
      vc::diagnose(GV.getContext(), "GenXSLMResolution",
                   "SLM variables must have local linkage", &GV);
      continue;
    }
    SLMVars.push_back(&GV);
  }
  return SLMVars;
}

llvm::Align
GenXSLMResolution::getGlobalVarAlign(const GlobalVariable &GV) const {
  if (GV.getAlignment())
    return IGCLLVM::getAlign(GV);
  return IGCLLVM::getABITypeAlign(*DL, GV.getValueType());
}

Constant *GenXSLMResolution::getNextOffset(llvm::Align Alignment,
                                           LLVMContext &Ctx,
                                           unsigned &SLMSize) const {
  SLMSize = llvm::alignTo(SLMSize, Alignment);
  unsigned SLMOffset = SLMSize ? SLMSize : genx::SlmNullProtection;
  auto *Offset = ConstantInt::get(Type::getInt32Ty(Ctx), SLMOffset);
  return Offset;
}

Constant *GenXSLMResolution::allocateOnSLM(const GlobalVariable &GV,
                                           unsigned &SLMSize) const {
  auto *PtrTy = cast<PointerType>(GV.getType());
  auto Align = getGlobalVarAlign(GV);
  auto *ElemTy = GV.getValueType();
  auto *Offset = getNextOffset(Align, GV.getContext(), SLMSize);
  auto TypeSize = DL->getTypeStoreSize(ElemTy);
  SLMSize += TypeSize;
  return ConstantExpr::getIntToPtr(Offset, PtrTy);
}

void GenXSLMResolution::replaceSLMVariablesWithOffsets(
    SmallVectorImpl<GlobalVariable *> &Workload,
    SmallPtrSetImpl<Function *> &FunctionSet, unsigned &SLMSize) const {
  llvm::stable_sort(Workload, [this](const auto *lhs, const auto *rhs) {
    return getGlobalVarAlign(*lhs) > getGlobalVarAlign(*rhs);
  });
  for (auto *GV : Workload) {
    auto *Offset = allocateOnSLM(*GV, SLMSize);
    IGCLLVM::replaceUsesWithIf(GV, Offset, [this, &FunctionSet](const Use &U) {
      return isUserInList(*U.getUser(), FunctionSet);
    });
  }
}

bool GenXSLMResolution::runForKernel(Function &Head, Module &M,
                                     ArrayRef<GlobalVariable *> SLMVars) {
  bool Modified = false;
  vc::KernelMetadata KM{&Head};
  unsigned SLMSize = KM.getSLMSize();

  if (!SLMVars.empty()) {
    // Traverse call graph to get all functions that are invoked from Head.
    auto FunctionSet = traverseCallGraph(Head, *CG);

    // Get all SLM variables that have users in any function from list.
    SmallVector<GlobalVariable *, 4> Workload;
    for (auto *GV : SLMVars) {
      if (isBelongToKernel(*GV, FunctionSet))
        Workload.push_back(GV);
    }
    if (!Workload.empty()) {
      replaceSLMVariablesWithOffsets(Workload, FunctionSet, SLMSize);
      KM.updateSLMSizeMD(SLMSize);
      Modified = true;
    }
  }

  // The first SLM kernel argument can be replaced with offset.
  // As a result, we make the pointer non-zero and get some
  // perfomance (due to a constant folding later).
  auto *Arg = llvm::find_if(Head.args(), [](Argument &A) {
    auto *PtrTy = dyn_cast<PointerType>(A.getType());
    return PtrTy && (vc::getAddrSpace(PtrTy) == vc::AddrSpace::Local);
  });
  if (Arg == Head.arg_end())
    return Modified;

  const auto &ST = getAnalysis<TargetPassConfig>()
                       .getTM<GenXTargetMachine>()
                       .getGenXSubtarget();
  auto Alignment =
      ST.translateLegacyMessages() ? llvm::Align(8) : llvm::Align(16);
  auto *Offset = getNextOffset(Alignment, Head.getContext(), SLMSize);
  auto *NewPtr = ConstantExpr::getIntToPtr(Offset, Arg->getType());
  Arg->replaceAllUsesWith(NewPtr);
  return true;
}

bool GenXSLMResolution::runOnModule(Module &M) {
  CG = &getAnalysis<CallGraphWrapperPass>().getCallGraph();
  DL = &M.getDataLayout();

  bool Modified = false;
  SmallVector<Instruction *, 4> SLMInitToErase;
  for (auto &F : M.functions()) {
    for (auto &Inst : instructions(F)) {
      if (GenXIntrinsic::getGenXIntrinsicID(&Inst) ==
          GenXIntrinsic::genx_slm_init) {
        lowerSlmInit(Inst);
        SLMInitToErase.push_back(&Inst);
        Modified = true;
      }
    }
  }
  llvm::for_each(SLMInitToErase, [](Instruction *I) { I->eraseFromParent(); });

  auto SLMVars = collectSLMVariables(M);
  if (!SLMVars.empty())
    for (auto &F : M.functions()) {
      if (F.isDeclaration())
        continue;
      Modified |=
          vc::breakConstantExprs(&F, vc::LegalizationStage::NotLegalized);
    }

  for (auto &F : M.functions())
    if (vc::isKernel(&F))
      Modified |= runForKernel(F, M, SLMVars);
  return Modified;
}
