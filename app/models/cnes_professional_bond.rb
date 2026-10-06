# Vínculo de profissional no retrato do CNES (ADR 0028). CPF e CNS cifrados com
# a chave da PLATAFORMA (key_provider fixo, como City#database_url) — dado
# pessoal de profissional, não de cidadão; sai mascarado nas telas.
class CnesProfessionalBond < PlatformRecord
  belongs_to :snapshot, class_name: "CnesSnapshot"

  encrypts :cpf, key_provider: PlatformKeyProvider.new
  encrypts :cns, key_provider: PlatformKeyProvider.new

  def cpf_masked = cpf && CitizenIdentity::Cpf.mask(cpf)
  def cns_masked = Professionals::Cns.mask(cns)
end
