# app/services/signatures/package.rb
# Exportação validável fora do sistema (spec §7; NGS2.06.03): o JSON canônico
# exatamente como foi assinado e o CAdES destacado (.p7s) — o par que o
# validar.iti.gov.br aceita. Assinatura do PSC simulado (só fora de produção):
# um terceiro arquivo de aviso e o nome do pacote dizem que não vale.
module Signatures
  module Package
    SIMULATED_NOTICE = "Assinatura simulada — sem validade jurídica. PSC simulado de desenvolvimento.\n".freeze
    SIMULATED_ENTRY = "AVISO-ASSINATURA-SIMULADA.txt".freeze

    module_function

    def filename(signature) = signature.simulated? ? "documento-assinado-simulado.zip" : "documento-assinado.zip"

    def zip(signature)
      Zip::OutputStream.write_buffer(StringIO.new) do |zip|
        zip.put_next_entry("document.json")
        zip.write(signature.canonical_json)
        zip.put_next_entry("document.json.p7s")
        zip.write(signature.cades_bytes)
        if signature.simulated?
          zip.put_next_entry(SIMULATED_ENTRY)
          zip.write(SIMULATED_NOTICE)
        end
      end.string
    end
  end
end
