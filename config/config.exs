# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

# The only Ash resources in this repo are the fake host's, exercised by the
# test suite; declare its domain so Spark's inclusion verification passes.
config :ash_acp, ash_domains: [FakeHost.Domain]

# Ash 3.x requires an explicit string-length counting strategy; codepoints
# matches how SQL data layers count, keeping validation consistent.
config :ash, default_string_length_count: :codepoints
