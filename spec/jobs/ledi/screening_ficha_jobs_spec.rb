require "rails_helper"

# ADR 0030 (spec §5): a ficha nasce no fechamento do atendimento e no
# varredor das 23h (fuso da cidade) para escutas concluídas de atendimentos
# ainda abertos; nunca duas (Review Focus 4 e 5).
RSpec.describe "Jobs da ficha da escuta" do
  include ActiveSupport::Testing::TimeHelpers

  let(:city) do
    record = City.find_by(slug: TEST_CITY_A.slug) ||
             create(:city, slug: TEST_CITY_A.slug, database_url: TEST_CITY_A.database_url, time_zone: "America/Manaus")
    ledi_ready!(record, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "1302603")
  end
  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }

  around { |ex| CityConnection.with(city) { ex.run } }
  before do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear # o adaptador de teste acumula entre exemplos
    ciap2_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
    exportable_unit!(unit, nurse)
  end

  def same_day!(n)
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(n))
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "same_day",
                              destination_params: {}, by: nurse)
    started.reload
  end

  def enqueued_ficha_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == Ledi::ScreeningFichaJob }
  end

  def run_enqueued!
    enqueued_ficha_jobs.each { |job| Ledi::ScreeningFichaJob.perform_now(**ActiveJob::Arguments.deserialize(job[:args]).first) }
  end

  it "a cidade de teste está em Manaus (o varredor depende do fuso)" do
    expect(city.time_zone).to eq("America/Manaus")
  end

  it "o destino que fecha o atendimento enfileira a ficha; o job a gera" do
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso" }, by: nurse)
    expect(enqueued_ficha_jobs.size).to eq(1)
    run_enqueued!
    expect(LediOutboxEntry.where(source_type: "Screening", source_id: started.id).count).to eq(1)
  end

  it "same_day só enfileira quando o profissional encerra o atendimento" do
    screening = same_day!(1)
    expect(enqueued_ficha_jobs).to be_empty
    doctor = screener!(unit, cbo: "225125")
    Attendances::Call.call(attendance: screening.attendance, health_unit_id: unit.id, by: doctor)
    Attendances::Close.call(attendance: screening.attendance.reload, outcome: "discharged", referral_unit_id: nil,
                            referral_note: nil, by: doctor)
    expect(enqueued_ficha_jobs.size).to eq(1)
  end

  it "varredor às 23h em Manaus (não em São Paulo); depois o fechamento não duplica (Review Focus 4 e 5)" do
    screening = same_day!(1)
    travel_to(Time.utc(2026, 10, 8, 2, 10)) do # 22h10 em Manaus, 23h10 em São Paulo
      Ledi::ScreeningFichaSweepJob.perform_now
    end
    expect(LediOutboxEntry.count).to eq(0)
    travel_to(Time.utc(2026, 10, 8, 3, 10)) do # 23h10 em Manaus
      Ledi::ScreeningFichaSweepJob.perform_now
    end
    expect(LediOutboxEntry.where(source_id: screening.id).count).to eq(1)

    doctor = screener!(unit, cbo: "225125")
    Attendances::Call.call(attendance: screening.attendance, health_unit_id: unit.id, by: doctor)
    Attendances::Close.call(attendance: screening.attendance.reload, outcome: "discharged", referral_unit_id: nil,
                            referral_note: nil, by: doctor)
    run_enqueued!
    expect(LediOutboxEntry.where(source_id: screening.id).count).to eq(1)
  end

  it "o varredor ignora escuta em curso (sem conclusão não há ficha)" do
    in_progress = Screenings::Start.call(attendance: walk_in_attendance!(unit, citizen: screening_citizen!(2)), by: nurse)
                                   .payload[:screening]
    travel_to(Time.utc(2026, 10, 8, 3, 10)) { Ledi::ScreeningFichaSweepJob.perform_now }
    expect([ LediOutboxEntry.where(source_id: in_progress.id).count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  # Atendimento já fechado (destino que encerra) com a exportação inutilizável no fechamento.
  def closed_while_unusable!(n, at: nil)
    return travel_to(at) { closed_while_unusable!(n) } if at

    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(n))
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    ledi_off!(city)
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso" }, by: nurse)
    run_enqueued!
    expect(attendance.reload.status).to eq("closed")
    started.reload
  end

  def usable_again! = ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "1302603")

  it "atendimento fechado sem ficha (exportação estava inutilizável): o varredor gera uma, uma só vez" do
    screening = closed_while_unusable!(4)
    expect(LediOutboxEntry.count).to eq(0)
    usable_again!
    2.times { |i| travel_to(Time.utc(2026, 10, 8, 3, 10 + i)) { Ledi::ScreeningFichaSweepJob.perform_now } }
    expect(LediOutboxEntry.where(source_type: "Screening", source_id: screening.id).count).to eq(1)
  end

  it "atendimento fechado e exportação ainda inutilizável no varredor: nada (nem 'não gerada')" do
    closed_while_unusable!(5)
    travel_to(Time.utc(2026, 10, 8, 3, 10)) { Ledi::ScreeningFichaSweepJob.perform_now }
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  it "atendimento fechado cuja escuta já tem 'não gerada' (resolvida ou não): o varredor não toca" do
    screening = closed_while_unusable!(6)
    LediGenerationFailure.create!(source_type: "Screening", source_id: screening.id,
                                  reason_codes: [ "citizen_without_sex" ], resolved_at: Time.current)
    usable_again!
    travel_to(Time.utc(2026, 10, 8, 3, 10)) { Ledi::ScreeningFichaSweepJob.perform_now }
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 1 ])
  end

  it "atendimento fechado com escuta concluída antes da competência anterior: ignorado" do
    old = closed_while_unusable!(7, at: Time.utc(2026, 8, 20, 12))
    recent = closed_while_unusable!(8, at: Time.utc(2026, 9, 2, 12)) # competência anterior: dentro
    usable_again!
    travel_to(Time.utc(2026, 10, 8, 3, 10)) { Ledi::ScreeningFichaSweepJob.perform_now }
    expect(LediOutboxEntry.pluck(:source_id)).to eq([ recent.id ])
  end

  it "exportação desligada no fechamento: nada; ligada no varredor (atendimento ainda aberto): nasce" do
    screening = same_day!(1)
    ledi_off!(city)
    travel_to(Time.utc(2026, 10, 8, 3, 10)) { Ledi::ScreeningFichaSweepJob.perform_now }
    expect(LediOutboxEntry.count).to eq(0)
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "1302603")
    travel_to(Time.utc(2026, 10, 8, 3, 20)) { Ledi::ScreeningFichaSweepJob.perform_now }
    expect(LediOutboxEntry.where(source_id: screening.id).count).to eq(1)
  end

  it "exportação desligada no fechamento do atendimento: o job não gera nada (nem 'não gerada')" do
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(3))
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    ledi_off!(city)
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso" }, by: nurse)
    run_enqueued!
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  it "recurring.yml agenda o varredor a cada hora" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("default", "ledi_screening_ficha_sweep")
    expect(task).to include("class" => "Ledi::ScreeningFichaSweepJob", "schedule" => "every hour at minute 10")
  end
end
