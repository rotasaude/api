require "rails_helper"

# ADR 0035: configuração do PEC por cidade. A chave HMAC é cifrada com a
# chave da cidade e nunca aparece em inspect; a linha é única.
RSpec.describe PecSetting do
  it "cifra a chave, esconde no inspect e é linha única" do
    setting = PecSetting.create!(pec_origin: "https://pec.cidade.gov.br", hmac_key: "chave-secreta-0123456789",
                                 hmac_key_updated_at: Time.current, pec_origin_updated_at: Time.current)
    raw = ApplicationRecord.connection.select_value("SELECT hmac_key FROM pec_settings WHERE id = #{ApplicationRecord.connection.quote(setting.id)}")
    expect(raw).not_to include("chave-secreta")
    expect(setting.reload.hmac_key).to eq("chave-secreta-0123456789")
    expect(setting.inspect).not_to include("chave-secreta")
    expect(setting.inspect).to include("hmac_key_configured=true")
    expect(PecSetting.current).to eq(setting)
    expect { PecSetting.create! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "com origem e chave, pec_external_view fica utilizável (pedido M3)" do
    city = timeline_city!(record_mode: "integrated", clinical_record: false, pec: true)
    expect(Platform::Features.missing(city, "pec_external_view")).to eq(%w[pec_origin_missing pec_hmac_key_missing])
    pec_settings!
    expect(Platform::Features.missing(city, "pec_external_view")).to eq([])
    expect(Timeline::Gate.pec_usable?(city)).to be(true)
    PecSetting.current.update!(pec_origin: nil)
    expect(Platform::Features.missing(city, "pec_external_view")).to eq(%w[pec_origin_missing])
  end

  it "o banco recusa origem com caminho e chave sem data" do
    expect { PecSetting.create!(pec_origin: "https://pec.cidade.gov.br/esus") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_pec_settings_origin/)
    expect { PecSetting.create!(hmac_key: "chave-secreta-0123456789") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_pec_settings_key_updated/)
  end

  it "abertura justificada tem paciente OU par validado, nunca os dois nem nenhum" do
    user = staff_with("abre-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional")
    citizen = verified_citizen!(71)
    now = Time.current
    opening = ClinicalRecordOpening.create!(citizen: citizen, user: user, reason_code: "case_review",
                                            created_at: now, expires_at: now + 30.minutes)
    expect(opening.reload.citizen).to eq(citizen)
    expect { ClinicalRecordOpening.create!(user: user, reason_code: "case_review", created_at: now, expires_at: now + 1.minute) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_record_openings_person/)
  end
end
