;=========================== begin_copyright_notice ============================
;
; Copyright (C) 2017-2025 Intel Corporation
;
; SPDX-License-Identifier: MIT
;
;============================ end_copyright_notice =============================

; RUN: igc_opt --typed-pointers -igc-image-func-analysis -S %s -o %t.ll
; RUN: FileCheck %s --input-file=%t.ll

%spirv.Image._void_1_0_0_0_0_0_0 = type opaque

declare i32 @__builtin_IB_get_image_channel_order(i32 %img)

define i32 @foo(%spirv.Image._void_1_0_0_0_0_0_0 addrspace(1)* %img) nounwind {
  %1 = ptrtoint %spirv.Image._void_1_0_0_0_0_0_0 addrspace(1)* %img to i64
  %2 = trunc i64 %1 to i32
  %id = call i32 @__builtin_IB_get_image_channel_order(i32 %2)
  ret i32 %id
}

!igc.functions = !{!0}
!0 = !{i32 (%spirv.Image._void_1_0_0_0_0_0_0 addrspace(1)*)* @foo, !1}
!1 = !{!2, !3}
!2 = !{!"function_type", i32 0}
!3 = !{!"implicit_arg_desc"}

;CHECK: !{!"implicit_arg_desc", ![[A1:[0-9]+]]}
;CHECK: ![[A1]] = !{i32 26, ![[A2:[0-9]+]]}
;CHECK: ![[A2]] = !{!"explicit_arg_num", i32 0}

; The following metadata are needed to recognize functions using image/sampler arguments:
!IGCMetadata = !{!4}
!4 = !{!"ModuleMD", !5}
!5 = !{!"FuncMD", !6, !7}
!6 = !{!"FuncMDMap[0]", i32 (%spirv.Image._void_1_0_0_0_0_0_0 addrspace(1)*)* @foo}
!7 = !{!"FuncMDValue[0]", !8}
!8 = !{!"m_OpenCLArgBaseTypes", !9}
!9 = !{!"m_OpenCLArgBaseTypesVec[0]", !"image2d_t"}
