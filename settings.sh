################################################################################
# setup Xilinx Vivado FPGA tools
################################################################################

. /opt/Xilinx/Vivado/2016.4/settings64.sh

################################################################################
# setup cross compiler toolchain
################################################################################

export CROSS_COMPILE=arm-linux-gnueabihf-
