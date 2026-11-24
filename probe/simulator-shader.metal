#include <metal_stdlib>
using namespace metal;
kernel void simulator_test(device uint *value [[buffer(0)]], uint i [[thread_position_in_grid]]) { value[i] = 42; }
