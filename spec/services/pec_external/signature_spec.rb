require "rails_helper"

# Documentação oficial (docs/pesquisa/2026-10-11-pec-sistemas-externos.md):
# HMAC-SHA256 hex da URL completa até antes de &pec_sign=. O vetor abaixo foi
# calculado ao escrever o plano com
#   printf '%s' '<URL sem pec_sign>' | openssl dgst -sha256 -hmac '<chave>'
RSpec.describe PecExternal::Signature do
  KEY = "chave-de-teste-do-pec-0123456789abcdef".freeze
  UNSIGNED = "https://curitiba.rotasaude.app/pec/timeline?documento-profissional=52998224725" \
             "&documento-cidadao=11144477735&cnes=1234567&pec_timestamp=1791720000".freeze
  SIGN = "a96bfb4684cd099acce004db814a296a59854f21cd1b9d7f4cb589d59ef00f9b".freeze
  let(:at) { Time.at(1_791_720_000) }

  def verify(url, timestamp: "1791720000", now: at, key: KEY) = described_class.verify(url: url, key: key, timestamp: timestamp, now: now)

  it "confere o vetor independente; a mesma assinatura de novo é reenvio" do
    expect(verify("#{UNSIGNED}&pec_sign=#{SIGN}")).to eq(:ok)
    expect(verify("#{UNSIGNED}&pec_sign=#{SIGN}")).to eq(:pec_replayed)
    expect(PecSignatureUse.sole.signature_digest).to eq(Digest::SHA256.hexdigest(SIGN))
    expect(PecSignatureUse.sole.expires_at).to eq(at + 300)
  end

  it "URL mexida: ordem, parâmetro a mais, tamanho, chave errada; maiúsculas passam (Review Focus 2)" do
    reordered = UNSIGNED.sub("documento-profissional=52998224725&documento-cidadao=11144477735",
                             "documento-cidadao=11144477735&documento-profissional=52998224725")
    [ "#{reordered}&pec_sign=#{SIGN}", "#{UNSIGNED}&pec_sign=#{SIGN}&extra=1", "#{UNSIGNED}&pec_sign=#{SIGN[0, 63]}",
      "#{UNSIGNED}&pec_sign=", UNSIGNED, "#{UNSIGNED.sub('1234567', '7654321')}&pec_sign=#{SIGN}" ].each do |url|
      expect(verify(url)).to eq(:pec_signature_invalid), url
    end
    expect(verify("#{UNSIGNED}&pec_sign=#{SIGN}", key: "outra-chave-0123456789")).to eq(:pec_signature_invalid)
    expect(verify("#{UNSIGNED}&pec_sign=#{SIGN}", key: nil)).to eq(:pec_signature_invalid)
    expect(verify("#{UNSIGNED}&pec_sign=#{SIGN}", timestamp: "1791720001")).to eq(:pec_signature_invalid)
    expect(PecSignatureUse.count).to eq(0)
    expect(verify("#{UNSIGNED}&pec_sign=#{SIGN.upcase}")).to eq(:ok)
  end

  it "janela de 5 minutos para os dois lados" do
    url = "#{UNSIGNED}&pec_sign=#{SIGN}"
    expect(verify(url, now: at + 301)).to eq(:pec_expired)
    expect(verify(url, now: at - 301)).to eq(:pec_expired)
    expect(verify(url, now: at + 300)).to eq(:ok)
  end

  it "apaga usos vencidos antes de gravar" do
    PecSignatureUse.create!(signature_digest: "0" * 64, expires_at: at - 1, created_at: at - 600)
    verify("#{UNSIGNED}&pec_sign=#{SIGN}")
    expect(PecSignatureUse.pluck(:signature_digest)).to eq([ Digest::SHA256.hexdigest(SIGN) ])
  end
end
