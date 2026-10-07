# spec/invariants/screening_invariants_spec.rb
require "rails_helper"

# Módulo 18, critério de fechamento (ADR 0030, "Invariantes"). Cada bloco tem
# a mutação que precisa deixá-lo vermelho.
RSpec.describe "Invariantes do acolhimento (ADR 0030)", type: :request do
  before { Current.city = TEST_CITY_A; ciap2_release!; allow(Ledi::DeliverJob).to receive(:perform_later) }
  after { Current.reset }

  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:marker) { "MARCADOR-#{SecureRandom.hex(4)}" }
  def body = JSON.parse(response.body)

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def completed!(attendance, destination: "same_day", params: {}, **revision)
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params(**revision), destination: destination,
                              destination_params: params, by: nurse)
    started.reload
  end

  # Mutação: tirar o trigger attendances_screening_close_guard (ou a condição
  # de destino dele) de db/city_triggers.sql.
  it "atendimento só fecha de waiting com desfecho de escuta se houver escuta concluída com aquele destino" do
    nurse # criada antes: o lambda a referenciaria dentro da transação que dá rollback
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    close = lambda do |outcome, note = nil|
      ApplicationRecord.transaction(requires_new: true) do
        attendance.reload.update_columns(status: "closed", outcome: outcome, closed_by_user_id: nurse.id,
                                         closed_at: Time.current, referral_note: note)
      end
    end
    %w[scheduled_from_screening oriented].each do |outcome|
      expect { close.call(outcome) }.to raise_error(ActiveRecord::StatementInvalid, /requires a completed screening/)
    end
    expect { close.call("referred", "CAPS") }.to raise_error(ActiveRecord::StatementInvalid, /requires a completed screening/)
    completed!(attendance)
    expect { close.call("oriented") }.to raise_error(ActiveRecord::StatementInvalid, /requires a completed screening/)
  end

  # Mutação: tirar :note/:reason (ou :vitals/:ciap2) de filter_parameters, pôr
  # orientation_note no payload de screening.completed, ou citar
  # complaint_note/color_change_reason/orientation_note/screening_revisions em
  # app/services/analytics ou app/queries/analytics.
  it "nenhum texto livre da escuta em evento, log ou Analytics" do
    acolhimento!
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    log = capture_log do
      sign_in_as(nurse)
      json_post "/attendance/attendances/#{attendance.id}/screening"
      id = body["id"]
      json_post "/attendance/screenings/#{id}/complete",
                revision_params(complaint_note: "queixa #{marker}", final_color: "yellow",
                                vitals: { systolic: 185, diastolic: 110 },
                                color_change_reason: "justificativa #{marker}")
                  .merge(destination: "oriented", orientation_note: "orientação #{marker}")
      expect(response).to have_http_status(:ok)
    end
    surfaces = [ log, DomainEvent.pluck(:payload).to_json, ActiveJob::Base.queue_adapter.enqueued_jobs.to_json ]
    surfaces.each { |text| expect(text).not_to include(marker) }
    # sinais vitais e CIAP-2 viajam como parâmetros: o "Parameters:" do log os filtra
    params_lines = log.lines.grep(/Parameters:/).join
    expect(params_lines).to include("Parameters:")
    expect(params_lines).not_to match(/systolic|diastolic|185|"K86"/)
    analytics = Dir[Rails.root.join("app/{services,queries}/analytics/**/*.rb")].map { |f| File.read(f) }.join
    expect(analytics).not_to match(/complaint_note|color_change_reason|orientation_note|screening_revisions/)
  end

  # Mutação: devolver queixa ou sinais vitais em Screenings::Json.queue_block.
  it "a recepção nunca recebe queixa nem sinais vitais" do
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    screening = completed!(attendance, complaint_note: "queixa #{marker}", vitals: { systolic: 150, diastolic: 95 })
    sign_in_as(reception!)
    responses = []
    get "/attendance/units/#{unit.id}/queue"
    responses << response.body
    get "/attendance/units/#{unit.id}/screening_queue"
    responses << response.body
    get "/attendance/screenings/#{screening.id}"
    expect(response).to have_http_status(:forbidden)
    responses << response.body
    responses.each do |text|
      expect(text).not_to include(marker, "systolic", "vitals", "complaint", "ciap2")
    end
  end

  # Mutação: gravar Ledi::Outcome/corpo do 400 em qualquer coluna, ou um
  # Rails.logger com o corpo em Ledi::Delivery.
  it "nenhuma resposta crua do PEC é persistida nem logada; last_error_codes nunca contém valor" do
    stub_pec!
    allow(Ledi::Observations).to receive(:duplicate_marker).and_return(nil)
    allow(Ledi::DeliverJob).to receive(:perform_later).and_call_original
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    exportable_unit!(unit, nurse)
    screening = completed!(walk_in_attendance!(unit, citizen: screening_citizen!(1)), destination: "oriented",
                           params: { "orientation_note" => "repouso" })
    Ledi::ScreeningFicha.generate(screening, city: city)
    FakePec.for("https://pec.a.test").delivery_replies = [
      [ 400, { descricaoErro: "MARIA #{marker} nascida em 10/05/1980",
               errosValidacao: { cpfCidadao: "CPF 529.982.247-25 de MARIA #{marker} inválido" } }.to_json ]
    ]
    log = capture_log { Ledi::DeliverJob.perform_now }
    entry = LediOutboxEntry.sole
    expect(entry.status).to eq("rejected")
    expect(Ledi::ErrorCodes.valid?(entry.last_error_codes)).to be(true)
    stored = ApplicationRecord.connection.select_all("SELECT * FROM ledi_outbox").to_a.to_json
    [ stored, log, DomainEvent.pluck(:payload).to_json ].each do |text|
      expect(text).not_to include(marker, "MARIA", "529.982.247-25", "10/05/1980")
    end
  end

  # Mutação: trocar 90 por 900 em Ledi::PurgeStalePayloadsJob ou tirar
  # "failed" do where.
  it "nenhum payload de recusada/falha com última tentativa há mais de 90 dias depois da purga" do
    %w[rejected failed].each do |status|
      LediOutboxEntry.create!(uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: "202606",
                              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
                              status: status, next_attempt_at: Time.current, attempts: 1, bytes: "x".b,
                              last_attempted_at: 91.days.ago,
                              last_error_codes: [ { "field" => "cnes", "code" => "invalid" } ])
    end
    CityConnection.with(city) { Ledi::PurgeStalePayloadsJob.perform_now }
    stale = LediOutboxEntry.where(status: %w[rejected failed]).where.not(payload: nil)
                           .where("COALESCE(last_attempted_at, created_at) < ?", 90.days.ago)
    expect(stale).to be_empty
  end

  # Mutação: tirar o `return :unusable unless exportable?(city)` de
  # Ledi::ScreeningFicha.generate.
  it "a ficha da escuta nunca nasce com a exportação inutilizável" do
    exportable_unit!(unit, nurse)
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    IntegrationCredential.find_by!(kind: "ledi").update!(last_check_status: "unauthorized")
    first = completed!(walk_in_attendance!(unit, citizen: screening_citizen!(1)), destination: "oriented",
                       params: { "orientation_note" => "repouso" })
    Ledi::ScreeningFichaJob.perform_now(city_slug: city.slug, screening_id: first.id) # credencial recusada
    ledi_off!(city)
    second = completed!(walk_in_attendance!(unit, citizen: screening_citizen!(2)), destination: "oriented",
                        params: { "orientation_note" => "repouso" })
    Ledi::ScreeningFichaJob.perform_now(city_slug: city.slug, screening_id: second.id) # interruptor desligado
    expect(LediOutboxEntry.where(source_type: "Screening")).to be_empty
    expect(LediGenerationFailure.count).to eq(0)
  end
end
