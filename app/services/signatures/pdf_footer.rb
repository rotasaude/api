# Rodapé padronizado do PDF assinado (NGS2.06.05–07; "Valores fixados" 6):
# quem assinou (nome do certificado, CPF mascarado), quando (UTC), política e
# onde verificar. `simulated` (PSC simulado, só fora de produção) abre o texto
# com o aviso de que a assinatura não tem validade jurídica.
module Signatures
  # Aviso do PSC simulado (só fora de produção).
  PdfFooter = Data.define(:signer_name, :signer_cpf, :signed_at, :simulated) do
    def initialize(signer_name:, signer_cpf:, signed_at:, simulated: false) = super

    def text
      "#{PdfFooter::SIMULATED_NOTICE if simulated}Documento assinado digitalmente por #{signer_name} " \
        "(CPF #{CitizenIdentity::Cpf.mask(signer_cpf)}) em " \
        "#{signed_at.utc.strftime('%d/%m/%Y %H:%M')} UTC — ICP-Brasil, política AD-RB. Verifique em https://validar.iti.gov.br"
    end

    def inspect = "#<Signatures::PdfFooter>"
    alias_method :to_s, :inspect
  end

  PdfFooter::SIMULATED_NOTICE = "Assinatura simulada — sem validade jurídica (desenvolvimento). ".freeze
end
