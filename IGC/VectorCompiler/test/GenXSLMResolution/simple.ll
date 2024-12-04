;=========================== begin_copyright_notice ============================
;
; Copyright (C) 2022-2024 Intel Corporation
;
; SPDX-License-Identifier: MIT
;
;============================ end_copyright_notice =============================

; RUN: %opt_typed_ptrs %use_old_pass_manager% -GenXSLMResolution -march=genx64 -mcpu=Gen9 -mtriple=spir64-unknown-unknown -S < %s | FileCheck %s --check-prefix=CHECK-TYPED-PTRS
; RUN: %opt_opaque_ptrs %use_old_pass_manager% -GenXSLMResolution -march=genx64 -mcpu=Gen9 -mtriple=spir64-unknown-unknown -S < %s | FileCheck %s --check-prefix=CHECK-OPAQUE-PTRS

target datalayout = "e-p:64:64-i64:64-n8:16:32"

@slm_i1 = internal unnamed_addr addrspace(3) global i1 undef
@slm_v2i8 = internal unnamed_addr addrspace(3) global <2 x i8> undef
@slm_struct_i64i8 = internal unnamed_addr addrspace(3) global { i64, i8 } undef
@slm_struct_align = internal unnamed_addr addrspace(3) global { i1 } undef, align 256

define dllexport spir_kernel void @kernel() #0 {

  ; CHECK-TYPED-PTRS: %load_i1 = load i1, i1 addrspace(3)* inttoptr (i32 26 to i1 addrspace(3)*)
  ; CHECK-OPAQUE-PTRS: %load_i1 = load i1, ptr addrspace(3) inttoptr (i32 26 to ptr addrspace(3))
  %load_i1 = load i1, i1 addrspace(3)* @slm_i1

  ; CHECK-TYPED-PTRS: %load_v2i8 = load <2 x i8>, <2 x i8> addrspace(3)* inttoptr (i32 24 to <2 x i8> addrspace(3)*),
  ; CHECK-OPAQUE-PTRS: %load_v2i8 = load <2 x i8>, ptr addrspace(3) inttoptr (i32 24 to ptr addrspace(3)),
  %load_v2i8 = load <2 x i8>, <2 x i8> addrspace(3)* @slm_v2i8

  ; CHECK-TYPED-PTRS: %load_struct_i64i8 = load { i64, i8 }, { i64, i8 } addrspace(3)* inttoptr (i32 8 to { i64, i8 } addrspace(3)*)
  ; CHECK-OPAQUE-PTRS: %load_struct_i64i8 = load { i64, i8 }, ptr addrspace(3) inttoptr (i32 8 to ptr addrspace(3))
  %load_struct_i64i8 = load { i64, i8 }, { i64, i8 } addrspace(3)* @slm_struct_i64i8

  ; CHECK-TYPED-PTRS: call void @llvm.genx.barrier()
  ; CHECK-OPAQUE-PTRS: call void @llvm.genx.barrier()
  call void @llvm.genx.barrier()

  ; CHECK-TYPED-PTRS: %load_struct_align = load { i1 }, { i1 } addrspace(3)* inttoptr (i32 268435456 to { i1 } addrspace(3)*)
  ; CHECK-OPAQUE-PTRS: %load_struct_align = load { i1 }, ptr addrspace(3) inttoptr (i32 268435456 to ptr addrspace(3))
  %load_struct_align = load { i1 }, { i1 } addrspace(3)* @slm_struct_align
  ret void
}

declare void @llvm.genx.barrier() #1

attributes #0 = { noinline nounwind "CMGenxMain" }
attributes #1 = { nounwind convergent }

!genx.kernels = !{!0}
!genx.kernel.internal = !{!3}

; CHECK-TYPED-PTRS: !{{[[:digit:]]}} = !{void ()* @kernel, !"kernel", !{{[[:digit:]]}}, i32 27, !{{[[:digit:]]}}, !{{[[:digit:]]}}, !{{[[:digit:]]}}, i32 0}
; CHECK-OPAQUE-PTRS: !{{[[:digit:]]}} = !{ptr @kernel, !"kernel", !{{[[:digit:]]}}, i32 27, !{{[[:digit:]]}}, !{{[[:digit:]]}}, !{{[[:digit:]]}}, i32 0}
!0 = !{void ()* @kernel, !"kernel", !1, i32 0, !1, !1, !2, i32 0}
!1 = !{}
!2 = !{!""}
!3 = !{void ()* @kernel, !1, !1, !1, !1}
