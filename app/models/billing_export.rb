# Arquivo de interface do BPA Magnético gerado no fechamento (ADR 0039;
# contracts/billing/bpa-interface.md): só acréscimo, cifrado com a chave da
# cidade (tem nome, CPF, nascimento do paciente). Nunca no inspect nem em log.
class BillingExport < ApplicationRecord
  encrypts :file

  belongs_to :billing_period
  belongs_to :generated_by_user, class_name: "User"

  def bytes = file.to_s.b
  def inspect = "#<BillingExport id=#{id} version=#{version} sha256=#{sha256}>"
end
