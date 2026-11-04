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

    # A guarda mora em Appointments::Placement.lock!, sob a trava da unidade:
    # os três comandos chegam lá com o resto das conferências prévias satisfeitas.
    it "Book, FitIn e Schedule recusam pedido com destino CAPS; nenhum horário" do
      professional = Struct.new(:id).new(SecureRandom.uuid)
      shift = Struct.new(:professional_id).new(professional.id)
      type = Struct.new(:active, :duration_minutes, :key).new(true, 20, "consulta_medica")
      book = Appointments::Book.call(request: request_to_caps, professional: professional, starts_at: future, type: type, by: staff)
      fit_in = Appointments::FitIn.call(request: request_to_caps, professional: professional, shift: shift, starts_at: future, type: type,
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

  # Fix round 1 (P51, G1): os cadastros que levam a pedido automático — a
  # cobertura do bairro (unidade de referência da triagem web) e o prestador
  # próprio da regulação — também recusam o CAPS; a leitura da cobertura
  # ignora o CAPS gravado antes (dado antigo).
  describe "cadastros e caminhos automáticos (P51)" do
    let(:neighborhood) { Neighborhood.create!(name: "Centro", source: "seed") }

    it "cobertura do bairro: recusa o CAPS (path health_unit_ids) sem mudar o que havia" do
      Territory::ReplaceCoverage.call(neighborhood: neighborhood, health_unit_ids: [ ubs.id ], by: nil)
      result = Territory::ReplaceCoverage.call(neighborhood: neighborhood, health_unit_ids: [ ubs.id, caps.id ], by: nil)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(result.details).to eq(path: "health_unit_ids")
      expect(neighborhood.coverages.pluck(:health_unit_id)).to eq([ ubs.id ])
    end

    it "unidade de referência ignora o CAPS gravado direto na cobertura (dado antigo)" do
      [ ubs, caps ].each { |unit| NeighborhoodCoverage.create!(neighborhood: neighborhood, health_unit: unit) }
      expect(Territory::ReferenceUnits.for(neighborhood.id)).to eq([ ubs ])
      expect(Territory::ReferenceUnits.ids_by_neighborhood([ neighborhood.id ])).to eq(neighborhood.id => [ ubs.id ])
    end

    it "prestador próprio da regulação: recusa o CAPS (path health_unit_id)" do
      caps.update!(cnes: "7654321")
      admin = staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      result = CareRegulation::SaveProvider.call(attrs: { "name" => "Prestador CAPS", "kind" => "own", "health_unit_id" => caps.id }, by: admin)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(result.details).to eq(path: "health_unit_id")
      expect(CareProvider.count).to eq(0)
    end

    it "linha de cuidado: equipe do CAPS não abre pedido de agendamento" do
      care_city!
      doctor = care_doctor!(caps)
      team = care_team!(caps, doctor)
      enrollment = care_enrollment!(patient: care_patient!(age: 70, sex: "female"), line: adopted_line!("elderly_c6"), team: team, by: doctor)
      result = CareLines::OpenAppointmentRequest.call(enrollment: enrollment, by: doctor)
      expect(reason_of(result)).to eq([ true, :caps_unit_not_allowed ])
      expect(AppointmentRequest.count).to eq(0)
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
