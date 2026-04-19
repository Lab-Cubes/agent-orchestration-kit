# Copyright 2024 NPS Kit Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# derive-budget-usd.py — derive the Claude CLI --max-budget-usd ceiling
#
# Usage: python3 derive-budget-usd.py <budget_npt> <config_file> <model> <category>
#
# Priority (lowest value wins — category_usd_cap is a CEILING, not the target):
#   1. budget_npt * model_rates[model].npt_usd + nop_overhead_usd (NPT-derived)
#   2. category_usd_cap[category]  — if present, caps the derived value
#   3. min floor of $0.50 always applies (Claude CLI minimum)
#
# Outputs the derived USD ceiling to stdout (two decimal places).

import json
import os
import sys

budget_npt = int(sys.argv[1])
config_file = sys.argv[2]
model = sys.argv[3]
category = sys.argv[4]

if config_file and os.path.exists(config_file):
    d = json.load(open(config_file))
    rate = d.get('model_rates', {}).get(model, {}).get('npt_usd', 0.000025)
    overhead = d.get('nop_overhead_usd', 0.0)
    budget_derived = budget_npt * rate + overhead
    cap = d.get('category_usd_cap', {}).get(category)
    if cap is not None:
        result = max(0.50, min(float(cap), budget_derived))
    else:
        result = max(0.50, budget_derived)
else:
    budget_derived = budget_npt * 0.000025
    result = max(0.50, budget_derived)

print(f"{result:.2f}")
