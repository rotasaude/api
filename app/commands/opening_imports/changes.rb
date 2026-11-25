# Recusas comuns aos atos sobre a importação do saldo inicial (Q20).
module OpeningImports
  module Changes
    module_function

    def version_required = Result.fail(:expected_version_required, details: { path: "expected_version" })
    def changed = Result.fail(:opening_import_changed)
  end
end
