require "rails_helper"

# Módulo 26a, Task 4 (contrato §2 `<regulation_request>`; plano, Desvio 13): a
# forma JSON do pedido e a trilha. Pedidos fora de draft vêm de update_columns
# sobre o rascunho real (as transições são das tasks seguintes).
RSpec.describe CareRegulation::Json do
  let!(:city) { regulation_city! }
  let(:unit) { create_unit("UBS Forma") }
  let(:doctor) { doctor!(unit) }
  let(:request) { regulation_request!(status: "draft", unit: unit, doctor: doctor) }
  let(:today) { Time.zone.today }

  def draft! = regulation_request!(status: "draft", unit: unit, doctor: doctor)

  def sent!(row, status: "pending", **over)
    row.update_columns({ status: status, requested_at: Time.current, due_on: today + 10 }.merge(over))
    RegulationRequest.find(row.id)
  end

  def authorize!(row, release: false)
    provider = external_provider!(kind: "contracted", name: "Clínica de Olhos Araucária")
    auth = RegulationAuthorization.create!(regulation_request: row, care_offer: offer!(provider: provider),
                                           authorized_by_user: regulation_admin!, month: Time.zone.today.beginning_of_month,
                                           skip_reason: "Paciente com urgência documentada")
    auth.update_columns(released_at: Time.current, release_reason: "cancelled") if release
    auth
  end

  describe ".request" do
    it "rascunho: chaves na ordem do contrato, sem dado de autorização nem de agendamento" do
      json = described_class.request(request)
      expect(json.keys).to eq(%i[id patient type target cid10 ciap2 justification suggested_color color color_reason status
                                 requested_at due_on overdue requester consultation_id authorization appointment_request_id
                                 schedule outcome misses external state_regulated version events])
      expect(json).to include(status: "draft", requested_at: nil, due_on: nil, overdue: false, authorization: nil, schedule: nil,
                              outcome: nil, external: nil, events: [])
    end

    it "authorization: vigente com prestador, mês YYYY-MM, motivo de pular, quem e quando; liberada não aparece em pending" do
      row = sent!(draft!)
      auth = authorize!(row, release: true)
      expect(described_class.request(RegulationRequest.find(row.id))[:authorization]).to be_nil

      row = sent!(draft!, status: "authorized")
      live = authorize!(row)
      shown = described_class.request(RegulationRequest.find(row.id))[:authorization]
      expect(shown).to eq(offer_id: live.care_offer_id, provider: { id: live.care_offer.care_provider_id, name: "Clínica de Olhos Araucária", kind: "contracted" },
                          month: today.strftime("%Y-%m"), skip_reason: "Paciente com urgência documentada",
                          at: live.created_at.iso8601, by: { name: Screenings::Json.staff_name(live.authorized_by_user) })
      expect(auth).to be_persisted
    end

    it "completed e closed mostram a última autorização, mesmo liberada" do
      row = sent!(draft!, status: "completed")
      authorize!(row, release: true)
      expect(described_class.request(RegulationRequest.find(row.id))[:authorization]).to include(month: today.strftime("%Y-%m"))
    end

    it "schedule só com horário; outcome completed, missed (segunda falta) ou nulo; external só com número" do
      row = sent!(draft!, status: "scheduled", scheduled_at: Time.zone.local(2026, 11, 3, 14), schedule_place: "Clínica X",
                           schedule_notes: "Trazer exames")
      json = described_class.request(RegulationRequest.find(row.id))
      expect(json[:schedule]).to eq(at: Time.zone.local(2026, 11, 3, 14).iso8601, place: "Clínica X", notes: "Trazer exames")
      expect(json[:outcome]).to be_nil

      expect(described_class.request(sent!(draft!, status: "completed"))[:outcome]).to eq("completed")
      expect(described_class.request(sent!(draft!, status: "closed", misses: 2))[:outcome]).to eq("missed")
      expect(described_class.request(sent!(draft!, status: "cancelled", misses: 1))[:outcome]).to be_nil

      with_number = sent!(draft!, status: "external", external_system: "care", external_number: "A-1/2026", state_regulated: true)
      expect(described_class.request(with_number)[:external]).to eq(system: "care", number: "A-1/2026")
      expect(described_class.request(request.reload)[:external]).to be_nil
    end

    it "overdue só esperando e com prazo vencido; list_item não leva events" do
      late = sent!(draft!, due_on: today - 1)
      expect(described_class.request(late, today: today)[:overdue]).to be(true)
      expect(described_class.request(sent!(draft!, status: "scheduled", due_on: today - 1))[:overdue]).to be(false)
      item = described_class.list_item(late, today: today)
      expect(item).not_to have_key(:events)
      expect(item[:overdue]).to be(true)
      expect(described_class.request(late, events: false)).not_to have_key(:events)
    end

    it "events: by nulo quando o evento é do sistema; by com o nome quando é de uma pessoa" do
      row = sent!(draft!)
      RegulationRequestEvent.create!(regulation_request: row, status: "pending", by_user: doctor)
      RegulationRequestEvent.create!(regulation_request: row, status: "cancelled", by_user: nil, reason: "Pedido de agendamento encerrado")
      events = described_class.request(RegulationRequest.find(row.id))[:events]
      expect(events.map { |e| e[:status] }).to eq(%w[pending cancelled])
      expect(events.first).to include(by: { name: Screenings::Json.staff_name(doctor) }, reason: nil)
      expect(events.last).to include(by: nil)
      expect(events.last[:reason]).to eq("Pedido de agendamento encerrado")
    end

    it "o inspect e o as_json do modelo seguem sem dado pessoal (a forma é montada na mão)" do
      expect(request.inspect).not_to include(request.justification)
      expect(request.as_json.keys).to eq(%w[id status version])
    end
  end

  describe CareRegulation::Trail do
    it "person_viewed! e listed!: clinical_record.viewed com access regulation, só ids" do
      before = DomainEvent.where(name: "clinical_record.viewed").count
      described_class.person_viewed!(user: doctor, patient_id: request.patient_id)
      described_class.listed!(user: doctor, regulation_request_ids: [ request.id ])
      events = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).last(2)
      expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(before + 2)
      expect(events.map { |e| e.payload["access"] }).to all(eq("regulation"))
      expect(events.first.payload).to include("patient_id" => request.patient_id, "user_id" => doctor.id,
                                             "person_ref" => "patient:#{request.patient_id}")
      expect(events.last.payload).to include("regulation_request_ids" => [ request.id ], "user_id" => doctor.id)
      expect(events.last.payload.keys).not_to include("patient_id")
    end
  end
end
