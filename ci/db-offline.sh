#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
exec ./test-spinel.sh \
  test/db/api_surface_test.rb \
  test/db/ar_import_test.rb \
  test/db/architecture_contract_test.rb \
  test/db/arel_builder_test.rb \
  test/db/gen_emit_test.rb \
  test/db/int64_sentinel_test.rb \
  test/db/load_test.rb \
  test/db/nil_compare_test.rb \
  test/db/number_test.rb \
  test/db/pick_test.rb \
  test/db/query_sql_test.rb \
  test/db/shape_cache_test.rb \
  test/db/shape_cache_regression_test.rb \
  test/db/spinel_pinning_test.rb
