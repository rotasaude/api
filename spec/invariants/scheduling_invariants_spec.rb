# spec/invariants/scheduling_invariants_spec.rb
require "rails_helper"

# Módulo 17, critério de fechamento (ADR 0029, "Invariantes"). Onde o banco
# garante, o ataque é por SQL (insert_all/update_all); onde a garantia é a trava
# do comando, a prova sob disputa está em
# spec/commands/appointments/booking_concurrency_spec.rb e aqui fica a
# sequencial. Como em db/city_triggers.sql, isto NÃO defende contra o DONO da tabela.
RSpec.describe "Invariantes da agenda (ADR 0029)" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset; Rails.cache.clear }

  let(:unit) { create_unit }
  let(:link) { doctor_link!(unit) }
  let(:admin) { staff_with("admin-inv@cidade.gov.br", "municipal_admin") }
  let(:reception) { staff_with("recepcao-inv@cidade.gov.br", "citizen_verifier") }
  let(:shift) { shift!(link, starts_at: 4.days.from_now.change(hour: 8)) }
  let(:cpfs) { %w[52998224725 11144477735 39053344705 87748248800] }
  let(:consulta) { AppointmentType.find_by!(key: "consulta_medica") }
  def citizen(i) = Citizen.create!(cpf: cpfs[i], phone: "+55419#{format('%08d', 70_000_000 + i)}")
  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  def fit_in(request, starts_at, reason: "retorno que não espera")
    Appointments::FitIn.call(request: request, professional: link.professional, shift: shift,
                             starts_at: starts_at.iso8601, type: consulta, reason: reason, by: reception)
  end

  describe "nenhum horário slot ativo se sobrepõe a outro do mesmo profissional" do
    it "o banco recusa, mesmo por insert_all" do
      first = appointment_row!(triage_request!(citizen(0), unit: unit), shift, starts_at: shift.starts_at)
      other = triage_request!(citizen(1), unit: unit)
      row = first.attributes.except("id").merge("request_id" => other.id, "citizen_id" => other.citizen_id,
                                                "scheduled_at" => shift.starts_at + 5.minutes,
                                                "ends_at" => shift.starts_at + 25.minutes)
      expect { attempt { Appointment.insert_all!([ row ]) } }.to raise_error(ActiveRecord::ExclusionViolation)
      expect(Appointment.where(shift_id: shift.id).count).to eq(1)
    end
  end

  describe "nenhum turno passa do limite de encaixes" do
    it "o terceiro encaixe num turno de limite 2 é recusado" do
      expect(Scheduling::FitInLimit.for(shift)).to eq(2)
      requests = 3.times.map { |i| triage_request!(citizen(i), unit: unit) }
      results = requests.each_with_index.map { |request, i| fit_in(request, shift.starts_at + (i * 30).minutes) }

      expect(results.map { |r| r.ok? ? :ok : r.reason }).to eq([ :ok, :ok, :fit_in_limit ])
      expect(Scheduling::FitInLimit.count(shift)).to eq(2)
      expect(Appointment.where(request_id: requests.last.id)).to be_empty
      expect(requests.last.reload.status).to eq("open")
    end
  end

  describe "resultado urgente nunca gera pedido" do
    it "Triages::Schedule com prioridade urgente não grava nada; o mesmo resultado não urgente grava" do
      protocol = active_protocol!("saude-do-idoso", scheduling: [
        { "when" => { "gte" => [ "outcome.score", 0 ] }, "appointment_type" => "consulta_medica",
          "priority" => "priority", "due_in_days" => 1 }
      ])
      par = profiled_citizen!(age: 70)
      conversation = Conversation.create!(channel: "web", citizen: par, phone: par.phone, state: "completed")
      triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                              status: "completed", answers: { "q1" => "true" }, priority: 1, tier: "media")
      outcome = Struct.new(:tier, :score, :priority) { def terminal? = true }

      urgent = outcome.new("media", 4, 1)
      expect(Protocols::Urgency.urgent?(urgent)).to be(true)
      expect(Triages::Schedule.call(triage: triage, outcome: urgent)).to be_nil
      expect(AppointmentRequest.where(citizen: par)).to be_empty

      # Controle: a regra casa — só a urgência impediu o pedido.
      routine = outcome.new("media", 4, 5)
      expect(Protocols::Urgency.urgent?(routine)).to be(false)
      Triages::Schedule.call(triage: triage, outcome: routine)
      expect(AppointmentRequest.where(citizen: par).count).to eq(1)
    end
  end

  describe "mudança de turno ou modelo nunca apaga nem move horário marcado" do
    it "cancelar o turno, trocar ou editar o modelo deixam o horário igual; o banco recusa mover e apagar" do
      template = ScheduleTemplate.create!(name: "Manhã", blocks: [ { "starts" => "08:00", "ends" => "09:00",
                                                                     "kind" => "bookable",
                                                                     "appointment_type_key" => "consulta_medica" } ])
      expect(Professionals::SetShiftTemplate.call(shift: shift, schedule_template_id: template.id, by: admin))
        .to be_ok
      appt = appointment_row!(triage_request!(citizen(0), unit: unit), shift, starts_at: shift.starts_at)
      before = appt.reload.attributes

      expect(Scheduling::SaveTemplate.call(template: template, by: admin,
                                           attrs: { "blocks" => [ { "starts" => "10:00", "ends" => "11:00",
                                                                    "kind" => "blocked" } ] })).to be_ok
      expect(Professionals::SetShiftTemplate.call(shift: shift.reload, schedule_template_id: nil, by: admin))
        .to be_ok
      expect(Professionals::CancelShift.call(shift: shift.reload, reason: "troca de escala", by: admin)).to be_ok
      expect(shift.reload.cancelled_at).to be_present
      expect(appt.reload.attributes).to eq(before)

      other_shift = shift!(link, starts_at: 9.days.from_now.change(hour: 8))
      other_professional = doctor_link!(unit).professional_id
      { "scheduled_at" => appt.scheduled_at + 1.hour, "ends_at" => appt.ends_at + 1.hour,
        "professional_id" => other_professional, "shift_id" => other_shift.id }.each do |column, value|
        expect { attempt { Appointment.where(id: appt.id).update_all(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /scheduled columns never change/), column
      end
      expect { attempt { Appointment.where(id: appt.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect(appt.reload.attributes).to eq(before)
    end
  end

  describe "nenhum texto livre (motivo, justificativa) em evento, log ou Analytics" do
    it "encaixe e remarcação pedida não deixam o texto em domain_events; os parâmetros saem filtrados do log" do
      fitted = fit_in(triage_request!(citizen(0), unit: unit), shift.starts_at + 10.minutes,
                      reason: "gestante com sangramento")
      expect(fitted).to be_ok
      rescheduled = Appointments::RequestReschedule.call(appointment: fitted.payload[:appointment], reason_code: "health",
                                                         note: "tenho fisioterapia às 8h", preferred_period: "afternoon")
      expect(rescheduled).to be_ok
      expect(DomainEvent.pluck(:name)).to include("appointment.fit_in_created", "appointment.reschedule_requested")

      payloads = DomainEvent.pluck(:payload).to_json
      expect(payloads).not_to include("gestante", "fisioterapia", "Remarcação pedida")

      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter("reason" => "a", "note" => "b", "fit_in_reason" => "c", "reschedule_note" => "d")
      expect(filtered.values).to all(eq("[FILTERED]"))
    end

    it "nada de Analytics lê as colunas de texto livre da agenda" do
      sources = Dir[Rails.root.join("app/services/analytics/**/*.rb")].map { |f| File.read(f) }.join
      expect(sources).not_to be_empty
      expect(sources).not_to match(/fit_in_reason|reschedule_note|cancel_reason|dismiss_reason/)
    end
  end

  describe "o cidadão nunca escolhe a vaga" do
    it "nenhuma rota do cidadão cria horário" do
      citizen_posts = Rails.application.routes.routes.filter_map do |route|
        path = route.path.spec.to_s
        path.delete_suffix("(.:format)") if route.verb == "POST" && path.start_with?("/citizen/appointments")
      end
      expect(citizen_posts).to contain_exactly("/citizen/appointments/:id/confirm", "/citizen/appointments/:id/cancel",
                                               "/citizen/appointments/:id/check_in_code",
                                               "/citizen/appointments/:id/reschedule_request")
    end

    it "pedir outro horário pela API ignora qualquer início, profissional ou turno enviado", type: :request do
      person = citizen(0)
      request = triage_request!(person, unit: unit)
      appt = appointment_row!(request, shift, starts_at: shift.starts_at)
      request.update!(status: "scheduled")
      free_shift = shift!(link, starts_at: 6.days.from_now.change(hour: 8))
      sign_in_citizen(person.phone)

      json_post "/citizen/appointments/#{appt.id}/reschedule_request",
                reason_code: "work", preferred_period: "any",
                starts_at: (free_shift.starts_at + 1.hour).iso8601, scheduled_at: (free_shift.starts_at + 1.hour).iso8601,
                professional_id: link.professional_id, shift_id: free_shift.id, appointment_type_key: "consulta_medica"

      expect(response).to have_http_status(:ok)
      expect(Appointment.where(citizen_id: person.id).count).to eq(1) # cancelou o horário; nenhum novo nasceu
      expect(Appointment.where(status: Appointment::LIVE)).to be_empty
      expect(Appointment.where(shift_id: free_shift.id)).to be_empty
      expect(appt.reload.status).to eq("cancelled_by_citizen")
      expect(request.reload).to have_attributes(status: "open", reopened_reason: "citizen_reschedule")
    end
  end
end
