# spec/services/analytics/publish_spec.rb
require "rails_helper"

# Spec §5 (ADR 0025): seis indicadores semanais da cidade inteira, já
# suprimidos, no banco de plataforma. Idempotente; taxa sem denominador não é
# gravada; o número de 1 a 4 nunca sai.
RSpec.describe Analytics::Publish do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city_record) { register_test_city! }
  let(:monday) { (Time.zone.today - 21).beginning_of_week }

  def published(week = monday)
    CityAnalyticsIndicator.where(city_id: city_record.id, week_start: week).order(:indicator)
                          .pluck(:indicator, :value, :suppressed).map { |i, v, s| [ i, v&.to_f, s ] }
  end

  before do
    fact!(metric: "triage.started", day: monday, value: 3)
    fact!(metric: "triage.started", day: monday + 1, value: 3)          # 6: soma antes de suprimir
    fact!(metric: "triage.completed", day: monday + 2, value: 3, tier: "alta")
    fact!(metric: "attendance.closed", day: monday, value: 10, dim: "discharged", health_unit_id: SecureRandom.uuid)
    fact!(metric: "attendance.closed", day: monday + 6, value: 2, dim: "left", health_unit_id: SecureRandom.uuid)
    fact!(metric: "attendance.wait", day: monday, value: 6, dim: "0-15")
    fact!(metric: "attendance.wait", day: monday, value: 5, dim: "15-30")
    fact!(metric: "attendance.wait", day: monday + 3, value: 11, dim: "30-60")
    fact!(metric: "appointment.ended", day: monday + 7, value: 9, dim: "checked_in") # semana seguinte
  end

  it "grava os seis indicadores da semana: contagem, suprimido e taxa; sem denominador, nada" do
    described_class.call(from: monday, to: monday + 6)

    expect(published).to eq([
      [ "attendances_closed", 12.0, false ],
      [ "left_pct", nil, true ],               # numerador 2
      [ "triages_completed", nil, true ],      # 3
      [ "triages_started", 6.0, false ],
      [ "wait_within_30_pct", 50.0, false ]    # 11 ÷ 22
    ])
    expect(CityAnalyticsIndicator.where(indicator: "no_show_pct")).to be_empty
  end

  it "publica todas as semanas tocadas pela janela" do
    described_class.call(from: monday + 5, to: monday + 8)

    expect(published(monday).map(&:first)).to include("triages_started")
    expect(published(monday + 7)).to eq([
      [ "attendances_closed", 0.0, false ], [ "no_show_pct", 0.0, false ],
      [ "triages_completed", 0.0, false ], [ "triages_started", 0.0, false ]
    ])
  end

  it "é idempotente e tira a linha que deixou de ter dado" do
    stale = CityAnalyticsIndicator.create!(city: city_record, week_start: monday, indicator: "no_show_pct", value: 40,
                                           suppressed: false, published_at: 2.days.ago)
    2.times { described_class.call(from: monday, to: monday + 6) }

    expect(CityAnalyticsIndicator.where(city_id: city_record.id, week_start: monday).count).to eq(5)
    expect(CityAnalyticsIndicator.exists?(stale.id)).to be(false)
  end

  # Decisão de 2026-09-30 (verificação do módulo 14): só semana fechada —
  # segunda + 6 ≤ ontem. A semana corrente nunca é gravada, e a linha dela de
  # uma publicação anterior sai na republicação.
  it "janela terminando numa quarta: a semana dessa quarta não sai; a anterior, sim" do
    wednesday = monday + 9
    previous = monday + 7
    fact!(metric: "triage.started", day: wednesday, value: 8)
    fact!(metric: "triage.started", day: previous, value: 8)
    leftover = CityAnalyticsIndicator.create!(city: city_record, week_start: wednesday.beginning_of_week,
                                              indicator: "triages_started", value: 5, suppressed: false,
                                              published_at: 2.days.ago)

    travel_to(local_at(wednesday + 1, 3)) { described_class.call(from: monday, to: wednesday) }

    expect(CityAnalyticsIndicator.where(city_id: city_record.id).distinct.pluck(:week_start))
      .to contain_exactly(monday)
    expect(CityAnalyticsIndicator.exists?(leftover.id)).to be(false)
  end

  it "domingo de ontem fecha a semana: ela sai" do
    sunday = monday + 6

    travel_to(local_at(sunday + 1, 3)) { described_class.call(from: monday, to: sunday) }

    expect(published.map(&:first)).to include("triages_started")
  end

  it "falha no insert: a transação da plataforma desfaz o delete e as linhas antigas ficam" do
    old = CityAnalyticsIndicator.create!(city: city_record, week_start: monday, indicator: "triages_started", value: 40,
                                         suppressed: false, published_at: 2.days.ago)
    allow(CityAnalyticsIndicator).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "PG::Error: boom")

    expect { described_class.call(from: monday, to: monday + 6) }.to raise_error(ActiveRecord::StatementInvalid)

    expect(CityAnalyticsIndicator.where(city_id: city_record.id).pluck(:id)).to eq([ old.id ])
    expect(old.reload.value.to_i).to eq(40)
  end

  # Suppression.rate: numerador 0 é visível, mas o denominador de 1 a 4
  # devolveria a contagem pequena (0 % de 3 faltas = 3 comparecimentos).
  it "taxa com denominador de 1 a 4 sai suprimida, mesmo com numerador 0" do
    fact!(metric: "appointment.ended", day: monday + 1, value: 3, dim: "checked_in")

    described_class.call(from: monday, to: monday + 6)

    expect(published).to include([ "no_show_pct", nil, true ])
  end

  it "purga só os indicadores da cidade com mais de 5 anos" do
    old_week = (Time.zone.today - 5.years - 7).beginning_of_week
    kept_week = (Time.zone.today - 5.years + 7).beginning_of_week
    other_city = create(:city)
    [ [ city_record, old_week ], [ city_record, kept_week ], [ other_city, old_week ] ].each do |city, week|
      CityAnalyticsIndicator.create!(city: city, week_start: week, indicator: "triages_started", value: 10,
                                     suppressed: false, published_at: Time.current)
    end

    described_class.call(from: monday, to: monday + 6)

    expect(CityAnalyticsIndicator.where(week_start: old_week).pluck(:city_id)).to eq([ other_city.id ])
    expect(CityAnalyticsIndicator.where(city_id: city_record.id, week_start: kept_week)).to exist
  end
end
