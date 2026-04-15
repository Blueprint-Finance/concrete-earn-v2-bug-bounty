#!/usr/bin/env python3
"""
Off-chain reference for ContinuousRateHurdleOracle.

Computes: baseRate * exp(targetAPR / 1e18 * elapsed / SECONDS_PER_YEAR)
using Python's arbitrary-precision Decimal arithmetic (78-digit mantissa),
then returns the result ABI-encoded as a uint256 on stdout.

Usage: python3 continuous_rate.py <baseRate> <targetAPR> <elapsed>
  - baseRate:   UD60x18-scaled (e.g. 1000000000000000000 = 1.0)
  - targetAPR:  UD60x18-scaled (e.g. 50000000000000000  = 5%)
  - elapsed:    seconds since baseline
"""
import sys
from decimal import Decimal, getcontext

getcontext().prec = 78

PRECISION = Decimal(10**18)
SECONDS_PER_YEAR = Decimal("31557600")  # 365.25 * 86400

base_rate_raw = int(sys.argv[1])
target_apr_raw = int(sys.argv[2])
elapsed = int(sys.argv[3])

if target_apr_raw == 0 or elapsed == 0:
    result = base_rate_raw
else:
    target_apr = Decimal(target_apr_raw) / PRECISION
    time_fraction = Decimal(elapsed) / SECONDS_PER_YEAR
    exponent = target_apr * time_fraction
    growth = exponent.exp()
    result = int(Decimal(base_rate_raw) * growth)

# ABI-encode as uint256 (32 bytes, hex, 0x-prefixed)
sys.stdout.write("0x" + format(result, "064x"))
