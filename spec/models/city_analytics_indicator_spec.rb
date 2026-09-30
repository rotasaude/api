require "rails_helper"

# Módulo 14 (ADR 0025; spec 2026-09-30 §3.3): o conjunto fixo da plataforma.
# O número de 1 a 4 nunca sai da cidade: suprimido é value NULL, e o banco
# recusa as duas combinações incoerentes.
RSpec.describe CityAnalyticsIndicator do
  let(:city) { create(:city) }
  let(:monday) { (Time.zone.today - 14).beginning_of_week }

  def indicator!(**attrs)
    PlatformRecord.transaction(requires_new: true) do
      described_class.create!({ city: city, week_start: monday, indicator: "triages_started", value: 12,
                                suppressed: false, published_at: Time.current }.merge(attrs))
    end
  end

  it "suprimido = value nulo, e o contrário também" do
    expect { indicator!(value: nil, suppressed: true) }.not_to raise_error
    expect { indicator!(indicator: "no_show_pct", value: 3, suppressed: true) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_city_analytics_indicators_suppressed/)
    expect { indicator!(indicator: "left_pct", value: nil, suppressed: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_city_analytics_indicators_suppressed/)
  end

  it "só os seis indicadores, só segunda-feira, uma linha por cidade × semana × indicador" do
    expect { indicator!(indicator: "triagens_de_tier_alto") }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_city_analytics_indicators_indicator/)
    expect { indicator!(week_start: monday + 1) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_city_analytics_indicators_monday/)
    indicator!
    expect { indicator! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "declara os seis indicadores na ordem do contrato e as três contagens" do
    expect(described_class::INDICATORS).to eq(%w[triages_started triages_completed attendances_closed
                                                 wait_within_30_pct no_show_pct left_pct])
    expect(described_class::COUNT_INDICATORS).to eq(%w[triages_started triages_completed attendances_closed])
  end
end
