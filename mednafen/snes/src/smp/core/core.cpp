//#include <../base.hpp>

#define SMPCORE_CPP
namespace bSNES_v059 {

#include "serialization.cpp"
#include "algorithms.cpp"

#define A  0
#define X  1
#define Y  2
#define SP 3

#include "opcode_mov.cpp"
#include "opcode_pc.cpp"
#include "opcode_read.cpp"
#include "opcode_rmw.cpp"
#include "opcode_misc.cpp"
#include "table.cpp"

#undef A
#undef X
#undef Y
#undef SP

};
