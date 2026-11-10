#!/usr/bin/env python3
"""
Off-chain reference for CompoundingHurdleRateOracle.

Computes: baseRate * (1 + targetAPY / 1e18) ^ (elapsed / SECONDS_PER_YEAR)
using Python's arbitrary-precision Decimal arithmetic (78-digit mantissa),
then returns the result ABI-encoded as a uint256 on stdout.

Usage: python3 compound_rate.py <baseRate> <targetAPY> <elapsed>
  - baseRate:   UD60x18-scaled (e.g. 1000000000000000000 = 1.0)
  - targetAPY:  UD60x18-scaled (e.g. 50000000000000000  = 5%)
  - elapsed:    seconds since baseline
"""
import sys
from decimal import Decimal, getcontext

getcontext().prec = 100

PRECISION = Decimal(10**18)
SECONDS_PER_YEAR = Decimal("31557600")  # 365.25 * 86400

base_rate_raw = int(sys.argv[1])
target_apy_raw = int(sys.argv[2])
elapsed = int(sys.argv[3])

if target_apy_raw == 0 or elapsed == 0:
    result = base_rate_raw
else:
    base_rate = Decimal(base_rate_raw) / PRECISION
    target_apy = Decimal(target_apy_raw) / PRECISION
    exponent = Decimal(elapsed) / SECONDS_PER_YEAR
    growth = (1 + target_apy) ** exponent
    result = int(Decimal(base_rate_raw) * growth)

# ABI-encode as uint256 (32 bytes, hex, 0x-prefixed)
sys.stdout.write("0x" + format(result, "064x"))
