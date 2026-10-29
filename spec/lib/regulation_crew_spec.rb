require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/regulation_crew").to_s

# Semente de dev do módulo 26a no banco de teste (nunca no de dev), com o
# elenco na ordem do db/seeds.rb até o CareLinesCrew (UBS, médica, recepção,
# José e Sebastião). Cada exemplo prova o que a prova no navegador precisa
# achar sem preparo manual: os dez pedidos na situação da tabela, a cota da
# ortopedia esgotada, o motivo de pular e a reguladora com OTP fixo.
# Idempotente; a saída nunca leva dado de paciente.
RSpec.describe RegulationCrew, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
  let(:regulator) { User.find_by!(email_address: "regulacao.municipal@curitiba.demo") }

  before do
    create_default_protocol!
    admin = staff_with("admin@curitiba.demo", "municipal_admin")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    Territory::Seed.call(path: Territory::Seed.path_for("curitiba"))
    TriageCatalogCrew.seed_current_city(slug: "curitiba", ddd: "41")
    ScreeningCrew.seed_platform!
    ScreeningCrew.seed_current_city(slug: "curitiba", ddd: "41")
    ClinicalRecordCrew.seed_platform!
    ClinicalRecordCrew.seed_current_city(slug: "curitiba", ddd: "41")
    CareLinesCrew.seed_platform!
    described_class.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def request(n) = described_class.request_of("curitiba", described_class::REQUESTS.find { |spec| spec[:n] == n })

  def offer(code) = CareOffer.find_by!(target_code: code, month: Time.zone.today.beginning_of_month)

  it "a plataforma: a SIGTAP de dev leva os reguláveis com BPA (competência corrente e anterior) e a CID-10 os diagnósticos" do
    today = Time.zone.today
    [ today, today << 1 ].each do |day|
      release = Terminology::Sigtap.release_for(day.strftime("%Y%m"))
      expect(release.version).to eq(day.strftime("%Y%m"))
      expect(SigtapProcedureInstrument.where(release_id: release.id, procedure_code: SigtapSample::REGULATION_CODES, instrument_code: %w[01 02])
                                      .distinct.pluck(:procedure_code)).to match_array(SigtapSample::REGULATION_CODES)
    end
    expect(CareRegulation::Targets.resolve(type: "procedure", code: "0209010037")).to be_ok
    expect(described_class::CID10.keys.map { |code| ClinicalTerms.find("cid10", code).present? }).to all(be(true))
    expect { expect(described_class.seed_platform!).to eq(sigtap: { competences: [ (today << 1).strftime("%Y%m"), today.strftime("%Y%m") ], status: :complete },
                                                          cid10: :complete) }
      .not_to(change { TerminologyRelease.count })
  end

  it "os dez pedidos na situação da tabela, a fila com os vencidos no topo e a cota da ortopedia esgotada" do
    result = seed
    statuses = (1..10).to_h { |n| [ n, request(n).status ] }

    aggregate_failures do
      expect(result[:switch]).to eq("ligado (care_regulation)")
      expect(statuses).to eq(1 => "pending", 2 => "pending", 3 => "pending", 4 => "pending", 5 => "authorized", 6 => "authorized",
                             7 => "scheduled", 8 => "returned", 9 => "external", 10 => "completed")
      expect(result[:requests]).to eq("authorized" => 2, "completed" => 1, "external" => 1, "pending" => 4, "returned" => 1, "scheduled" => 1)
      expect((1..10).map { |n| request(n).effective_color })
        .to eq(%w[red yellow green yellow yellow green yellow green blue green])
      expect([ request(1).requested_at.to_date, request(2).requested_at.to_date ]).to eq([ Time.zone.today - 10, Time.zone.today - 40 ])
      expect((1..10).select { |n| request(n).overdue? }).to eq([ 1, 2 ])
      expect(CareRegulation::Queue.counts).to include(pending: 4, overdue: 2, returned: 1, authorized: 2, external: 1)
      expect(CareRegulation::Queue.page(filters: {}, before: nil, limit: 50)[:rows].map(&:id)).to eq([ 1, 2, 4, 3 ].map { |n| request(n).id })

      # 5: a cota do consórcio esgotada (used = quantity = 1).
      orthopedics = offer(RegulationCrew::ORTHOPEDICS)
      expect([ CareRegulation::Quota.used([ orthopedics.id ]).fetch(orthopedics.id), orthopedics.quantity ]).to eq([ 1, 1 ])
      expect(orthopedics.care_provider.kind).to eq("consortium")

      # 6: rede própria, José, pedido de agendamento aberto no Centro de Especialidades.
      six = request(6)
      appointment = AppointmentRequest.find(six.appointment_request_id)
      expect([ appointment.status, appointment.kind, appointment.target_unit.name ]).to eq([ "open", "regulated", RegulationCrew::OWN_UNIT ])
      expect(appointment.citizen.cpf).to eq(CareLinesCrew.cpf_for("curitiba", :jose))
      expect(offer(RegulationCrew::CARDIOLOGY).care_provider).to have_attributes(kind: "own", cnes: appointment.target_unit.cnes)

      # 7: agendado na contratada daqui a 12 dias; 10: atendido.
      expect(request(7).scheduled_at.to_date).to eq(Time.zone.today + 12)
      expect(RegulationAuthorization.find_by!(regulation_request_id: request(7).id).care_offer.care_provider.name).to eq("Clínica de Olhos Araucária")
      expect(request(10).scheduled_at).to be < Time.current

      # 8: a EGD devolvida (alvo de procedimento, PPI com oferta); 9: no SISREG.
      expect([ request(8).target_type, request(8).target_code ]).to eq(%w[procedure 0209010037])
      expect(offer("0209010037").care_provider.kind).to eq("ppi")
      expect(request(9)).to have_attributes(state_regulated: true, external_system: "sisreg", external_number: "202610280001")

      # A médica pede com CID-10 (G12); a lista do enfermeiro; os prazos padrão.
      expect((1..10).map { |n| request(n).cid10 }).to all(be_present)
      expect(NurseRequestableItem.pluck(:target_code)).to match_array(%w[225250 225124])
      expect(RegulationRiskDeadline.count).to eq(4)
    end
    # O relógio voltou ao real.
    expect(Time.current).to be_within(5.minutes).of(Time.at(Process.clock_gettime(Process::CLOCK_REALTIME)))
  end

  it "motivo de pular: o 4 exige motivo enquanto o 1 e o 2 esperam, e continua exigindo depois de autorizar o 1 (pelo 2)" do
    seed
    cardiology = offer(RegulationCrew::CARDIOLOGY)
    four = request(4)
    authorize = ->(req) { CareRegulation::Authorize.call(request: req.reload, offer_id: cardiology.id, version: req.version, by: regulator) }

    expect(authorize.call(four).reason).to eq(:skip_reason_required)
    expect(authorize.call(request(1))).to be_ok
    expect(authorize.call(four).reason).to eq(:skip_reason_required)
  end

  it "a reguladora: papel care_regulator, OTP fixo do plano, e o regulacao@ do 21a não é tocado" do
    seed
    expect(regulator.has_role?("care_regulator")).to be(true)
    expect(regulator.otp_secret).to eq("REGULACAOMUNICIPALSEMENTEDEVCWBA")
    expect(User.exists?(email_address: "regulacao@curitiba.demo")).to be(false)
  end

  it "a segunda rodada não cria nada" do
    first = seed
    tables = [ User, Membership, Citizen, Patient, Attendance, Consultation, RegulationRequest, RegulationRequestEvent,
               RegulationAuthorization, AppointmentRequest, CareProvider, CareOffer, NurseRequestableItem, RegulationRiskDeadline,
               HealthUnit, DomainEvent, TerminologyRelease ]
    expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
  end

  it "a saída: só e-mail, papel e otpauth — nunca CPF nem nome de paciente" do
    lines = described_class.summary_lines(seed, password: "dev-password")
    text = ([ lines ] + [ seed.inspect ]).join("\n")
    names = described_class::PEOPLE.values.map { |p| p[:name] } + %i[jose sebastiao].map { |key| CareLinesCrew::PEOPLE.fetch(key)[:name] }
    cpfs = described_class::PEOPLE.keys.map { |key| described_class.cpf_for("curitiba", key) } +
           %i[jose sebastiao].map { |key| CareLinesCrew.cpf_for("curitiba", key) }

    expect(text).to include("regulacao.municipal@curitiba.demo (care_regulator)", "otpauth://")
    expect(names.select { |name| text.include?(name) }).to eq([])
    expect(cpfs.select { |cpf| text.include?(cpf) }).to eq([])
  end

  it "sem o mantenedor de dev não liga nada" do
    allow(Maintainer).to receive(:find_by).with(email_address: "dev@local").and_return(nil)
    result = nil
    expect { result = seed }.to output(/sem mantenedor de dev/).to_stderr
    expect(result).to include(switch: "desligado (sem mantenedor dev@local)", users: [])
    expect(RegulationRequest.count).to eq(0)
  end

  it "nos primeiros minutos do dia 1º para antes de ligar, dizendo quando semear; às 00:05 já não para" do
    first_day = Time.zone.today.next_month.beginning_of_month.in_time_zone
    travel_to(first_day + 4.minutes + 59.seconds) do
      expect { seed }.to raise_error(/semeie depois de 00:05 do dia 1º/)
    end
    expect([ CareRegulation::Gate.enabled?(Current.city), RegulationRequest.count, User.exists?(email_address: "regulacao.municipal@curitiba.demo") ])
      .to eq([ false, 0, false ])
    travel_to(first_day + 5.minutes) { expect { described_class.send(:guard_month_start!) }.not_to raise_error }
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", ddd: "44")).to include(switch: "fora", requests: {})
    expect(CareRegulation::Gate.enabled?(Current.city)).to be(false)
  end
end
