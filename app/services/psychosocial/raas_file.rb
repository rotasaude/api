# Arquivo da remessa RAAS-PSI do CAPS (ADR 0049; contrato §6, P15; plano,
# Desvio 9). Gerador puro, no padrão do Billing::BpaFile: recebe o cabeçalho e
# os registros já montados (Psychosocial::RaasRecords) e devolve o texto. Sem
# banco, sem log; o conteúdo nunca aparece em mensagem de erro.
#
# O layout oficial do aplicativo RAAS é gate (D6): o registro de layouts por
# versão entra VAZIO e `config/psychosocial/raas.yml` traz `layout_version:
# null`. Sem layout para a versão configurada a remessa é recusada antes de
# chamar `build` (ExportRaas → 422 raas_layout_unavailable). O layout oficial
# entra aqui, como uma constante a mais do registro, no gate.
module Psychosocial
  module RaasFile
    # writer: ->(header, records) { String }. `header` = { cnes:, competence:,
    # month: ("YYYY-MM"), unit_name: }; `records` = as fotos dos registros
    # (Hash, chaves em texto) com "actions" (as ações RAAS não canceladas do mês).
    Layout = Data.define(:version, :writer)

    LAYOUTS = {}.freeze

    module_function

    def available?(version) = version.is_a?(String) && LAYOUTS.key?(version)

    # -> String. KeyError com versão fora do registro (quem chama confere
    # available? antes; a mensagem cita só a versão).
    def build(version:, header:, records:)
      LAYOUTS.fetch(version).writer.call(header, records)
    end
  end
end
