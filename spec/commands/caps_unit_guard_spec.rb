require "rails_helper"

# Módulo 31 (ADR 0049; contrato P32, R11): a unidade CAPS nunca entra no
# check-in do módulo 09 nem na marcação do módulo 17 — senão o nome do CAPS
# iria para o atendimento, o pedido e o horário que o cidadão vê no wpda. Uma
# guarda em cada comando que cria atendimento, pedido com destino ou horário
# numa unidade escolhida: 422 caps_unit_not_allowed, nada gravado.
RSpec.describe "P32 — unidade CAPS fora do check-in e da marcação" do
  before do
    Current.city = TEST_CITY_A
    ensure_appointment_types!
  end
  after { Current.reset; Rails.cache.clear }

  let(:caps) { HealthUnit.create!(name: "CAPS II Boa Vista", kind: "caps", caps_modality: "caps_ii", service_classification: "001") }
  let(:ubs) { create_unit("UBS Centro") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:staff) { staff_with("atendente-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier") }

  def reason_of(result) = [ result.failure?, result.reason ]

  describe "check-in (módulo 09)" do
    let(:triage) { completed_web_triage_for(citizen) }

    it "por código: recusa o CAPS sem consumir o código; na UBS segue" do
      code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
      result = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: caps.id, document_checked: false, by: staff)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(Attendance.count).to eq(0)
      expect(DomainEvent.where(name: "attendance.checked_in")).to be_empty
      ok = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: ubs.id, document_checked: false, by: staff)
      expect(ok).to be_ok
    end

    it "por exceção (sem código): recusa o CAPS" do
      result = Attendances::CheckInByException.call(cpf: citizen.cpf, health_unit_id: caps.id, reason: "Celular sem bateria na recepção",
                                                    by: staff, triage_id: triage.id)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(Attendance.count).to eq(0)
    end
  end

  describe "marcação (módulo 17)" do
    let(:request_to_caps) { triage_request!(citizen, unit: caps) }
    let(:future) { (Time.current + 2.days).change(hour: 9).iso8601 }

    it "Book, FitIn e Schedule recusam pedido com destino CAPS; nenhum horário" do
      book = Appointments::Book.call(request: request_to_caps, professional: nil, starts_at: future, type: nil, by: staff)
      fit_in = Appointments::FitIn.call(request: request_to_caps, professional: nil, shift: nil, starts_at: future, type: nil,
                                        reason: "Encaixe por necessidade clínica", by: staff)
      schedule = Appointments::Schedule.call(request: request_to_caps, scheduled_at: future, health_unit_id: caps.id, by: staff)
      expect([ book, fit_in, schedule ].map { |result| reason_of(result) }).to all(eq([ true, :caps_unit_not_allowed ]))
      expect(Appointment.count).to eq(0)
      expect(request_to_caps.reload.status).to eq("open")
    end

    it "fila sem unidade: o CAPS não é destino possível" do
      request = triage_request!(citizen, unit: nil)
      result = AppointmentRequests::AssignUnit.call(request: request, unit_id: caps.id, by: staff)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(request.reload.target_unit_id).to be_nil
      expect(AppointmentRequests::AssignUnit.call(request: request, unit_id: ubs.id, by: staff)).to be_ok
    end

    it "encaminhamento no desfecho do atendimento: o CAPS não vira destino de pedido" do
      doctor = screener!(ubs, cbo: "225125")
      attendance = in_care!(walk_in_attendance!(ubs, citizen: citizen), by: doctor)
      result = Attendances::Close.call(attendance: attendance, outcome: "referred", referral_unit_id: caps.id, referral_note: nil, by: doctor)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(attendance.reload.status).to eq("in_care")
      expect(AppointmentRequest.where(target_unit_id: caps.id)).to be_empty
    end

    it "encaminhamento na escuta: o CAPS não vira destino de pedido" do
      ciap2_release!
      nurse = screener!(ubs)
      attendance = walk_in_attendance!(ubs, citizen: screening_citizen!(1))
      screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
      result = Screenings::Complete.call(screening: screening, revision_params: revision_params, destination: "referred",
                                         destination_params: { "referral" => { "referral_unit_id" => caps.id } }, by: nurse)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(screening.reload.status).not_to eq("completed")
      expect(AppointmentRequest.where(target_unit_id: caps.id)).to be_empty
    end

    it "esvaziamento de unidade: o CAPS não recebe pedidos nem horários" do
      admin = staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      triage_request!(citizen, unit: ubs)
      result = HealthUnits::Drain.call(unit: ubs, target_unit_id: caps.id, reason: "Reforma da unidade de saúde", by: admin)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(AppointmentRequest.where(target_unit_id: caps.id)).to be_empty
      expect(HealthUnitDrain.count).to eq(0)
    end
  end
end

RSpec.describe "P32 — recusa do CAPS pela API", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:caps) { HealthUnit.create!(name: "CAPS II Boa Vista", kind: "caps", caps_modality: "caps_ii", service_classification: "001") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { staff_with("atendente-#{SecureRandom.hex(3)}@cidade.gov.br", "citizen_verifier") }

  it "check-in num CAPS → 422 caps_unit_not_allowed" do
    code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: completed_web_triage_for(citizen)).payload.fetch(:code)
    sign_in_as(verifier)
    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: caps.id
    expect([ response.status, JSON.parse(response.body)["error"] ]).to eq([ 422, "caps_unit_not_allowed" ])
    expect(response.body).not_to include("Boa Vista")
  end
end
