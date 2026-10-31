.RECIPEPREFIX := >

MODELSIM_BIN ?= E:/intelFPGA/20.1/modelsim_ase/win32aloem
WORK ?= work
SRC_DIR ?= answer/code
TB_DIR ?= answer/code

VLOG ?= $(MODELSIM_BIN)/vlog.exe
VSIM ?= $(MODELSIM_BIN)/vsim.exe
VLIB ?= $(MODELSIM_BIN)/vlib.exe
VMAP ?= $(MODELSIM_BIN)/vmap.exe

CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2

# ping-pong testbench: file name and top-level module name
PP_TB  ?= tb_ping_pong_buffer
PP_FILE ?= $(TB_DIR)/$(PP_TB).v

RTL := $(SRC_DIR)/fp16_multiplier.v \
       $(SRC_DIR)/fp16_adder.v \
       $(SRC_DIR)/fp16_adder_model.v \
       $(SRC_DIR)/actel_gates.v \
       $(SRC_DIR)/modules.v \
       $(SRC_DIR)/relu_unit.v \
       $(SRC_DIR)/ping_pong_buffer.v \
       $(SRC_DIR)/layer2_regfile.v \
       $(SRC_DIR)/sram_weights_model.v \
       $(SRC_DIR)/sram_inputs_model.v \
       $(SRC_DIR)/fcnn_datapath.v \
       $(SRC_DIR)/fcnn_controller.v \
       $(SRC_DIR)/fcnn_top.v

VLOG_FLAGS := -sv -work $(WORK) +acc

.PHONY: all lib rtl mult add add_old pingpong top dbg wave vec_add clean c1 c2 s2-s1

all: top mult add pingpong

$(WORK)/_info:
> $(VLIB) $(WORK)
> $(VMAP) work $(WORK)

lib: $(WORK)/_info

rtl: lib
> $(VLOG) $(VLOG_FLAGS) $(RTL)

c1:
> $(CXX) $(CXXFLAGS) c1.cpp -o c1.exe

c2:
> $(CXX) $(CXXFLAGS) c2.cpp -o c2.exe

s2-s1:
> $(CXX) $(CXXFLAGS) s2-s1.cpp -o s2-s1.exe

cpp: c1 c2 s2-s1

mult: rtl
> $(VLOG) $(VLOG_FLAGS) $(SRC_DIR)/fp16_multiplier.v $(TB_DIR)/tb_fp16_multiplier.v
> $(VSIM) -c -work $(WORK) tb_fp16_multiplier -do "run -all; quit -f"

add: cpp lib
> $(VLOG) $(VLOG_FLAGS) $(SRC_DIR)/fp16_adder.v $(TB_DIR)/tb_fp16_adder.v
> $(VSIM) -c -work $(WORK) tb_fp16_adder -do "run -all; quit -f"

pingpong: rtl
> $(VLOG) $(VLOG_FLAGS) $(SRC_DIR)/ping_pong_buffer.v $(TB_DIR)/tb_ping_pong_buffer.v
> $(VSIM) -c -work $(WORK) tb_ping_pong_buffer -do "run -all; quit -f"

add_old: rtl
> $(VLOG) $(VLOG_FLAGS) $(TB_DIR)/tb_fp16_add_unit.v
> $(VSIM) -c -work $(WORK) tb_fp16_add_unit -do "run -all; quit -f"


top: cpp rtl
> $(VLOG) $(VLOG_FLAGS) $(TB_DIR)/tb_fcnn_top.v
> $(VSIM) -c -work $(WORK) tb_fcnn_top -do "run -all; quit -f"

dbg: rtl
> $(VLOG) $(VLOG_FLAGS) $(TB_DIR)/tb_dbg.v
> $(VSIM) -c -work $(WORK) tb_dbg -do "run -all; quit -f"

wave: rtl
> $(VLOG) $(VLOG_FLAGS) $(TB_DIR)/tb_fcnn_top.v
> $(VSIM) -work $(WORK) tb_fcnn_top -do "add wave -r /tb_fcnn_top/dut/*; run -all"

vec_add:
> cd answer/code/sim && py gen_vec_add_ca2.py

clean:
> rm -rf $(WORK) transcript vsim.wdb *.vcd modelsim.ini