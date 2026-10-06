require "rails_helper"

# Módulo 13, critério de fechamento (ADR 0018, 0019). As recusas vêm do banco
# (constraints e triggers de db/city_triggers.sql), não só do modelo: por isso
# os ataques usam update_all/insert_all e conferem a constraint ou a mensagem
# do trigger que recusou. Como em db/city_triggers.sql, isto NÃO defende contra
# o DONO da tabela.
RSpec.describe "Invariantes do atendimento (ADR 0018, 0019)" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; link_professional!(doctor, unit) }
  after { Current.reset; Rails.cache.clear }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:t0) { Time.zone.parse("2026-10-01 10:00") }
  let(:stranger) { Citizen.create!(cpf: "11144477735", phone: "+5541911112222") }

  let(:check_in_reason) { "chegou sem o celular" }
  let(:referral_note) { "avaliação da cardiologia com urgência" }
  let(:return_note) { "reavaliar a pressão em duas semanas" }

  # Savepoint: cada recusa aborta a transação; o savepoint deixa a próxima viva.
  def attempt(&block) = ApplicationRecord.transaction(requires_new: true, &block)

  # Linha nova de atendimento, pronta para insert_all, a partir de uma triagem
  # ainda sem atendimento (não esbarra no índice único).
  def fresh_row(**overrides)
    triage = completed_web_triage_for(citizen)
    { "triage_id" => triage.id, "appointment_id" => nil, "citizen_id" => citizen.id, "health_unit_id" => unit.id,
      "checked_in_by_user_id" => reception.id, "checked_in_at" => Time.current, "check_in_method" => "code",
      "exception_reason" => nil, "status" => "waiting", "created_at" => Time.current }.merge(overrides.transform_keys(&:to_s))
  end

  # Horário confirmado para hoje (nasce confirmado: menos de 48h), a partir de
  # um retorno. Chame dentro de travel_to(t0).
  def todays_appointment(for_citizen = citizen)
    first = in_care!(waiting_attendance(for_citizen, unit: unit, by: reception), by: doctor)
    req = Attendances::Close.call(attendance: first, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    # allow_overlap: os testes marcam vários horários no mesmo instante; o
    # aviso de conflito (api#26) não é o que se prova aqui.
    Appointments::Schedule.call(request: req, scheduled_at: (Time.current + 2.hours).iso8601, health_unit_id: unit.id,
                                by: reception, allow_overlap: true).payload.fetch(:appointment)
  end

  def closed!(attendance, outcome: "discharged")
    in_care!(attendance, by: doctor) if attendance.status == "waiting" && outcome != "left"
    Attendances::Close.call(attendance: attendance, outcome: outcome, referral_unit_id: nil,
                            referral_note: (outcome == "referred" ? referral_note : nil),
                            by: outcome == "left" ? reception : doctor).tap { |r| expect(r).to be_ok }
    attendance.reload
  end

  describe "todo atendimento nasce de uma triagem ou de um horário, nunca dos dois" do
    it "o banco recusa INSERT com triagem E horário (ck_attendances_origin)" do
      appt = travel_to(t0) { todays_appointment }
      row = fresh_row(appointment_id: appt.id)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_origin/)
    end

    it "o banco recusa INSERT sem triagem nem horário (ck_attendances_origin)" do
      row = fresh_row(triage_id: nil)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_origin/)
    end
  end

  describe "uma triagem e um horário têm no máximo um atendimento cada" do
    it "o banco recusa um segundo atendimento da mesma triagem, mesmo por insert_all" do
      a = waiting_attendance(citizen, unit: unit, by: reception)
      row = fresh_row(triage_id: a.triage_id, health_unit_id: other_unit.id)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_attendances_on_triage_id/)
    end

    it "o banco recusa um segundo atendimento do mesmo horário, mesmo por insert_all" do
      appt = travel_to(t0) { todays_appointment }
      travel_to(t0) do
        expect(Attendances::CheckInByException.call(cpf: citizen.cpf, appointment_id: appt.id, health_unit_id: unit.id,
                                                    reason: check_in_reason, by: reception)).to be_ok
      end
      row = fresh_row(triage_id: nil, appointment_id: appt.id, check_in_method: "cpf_exception",
                      exception_reason: check_in_reason)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_attendances_on_appointment_id/)
    end
  end

  describe "o check-in nunca muda" do
    # Todas as colunas guardadas por rota_attendance_guard (db/city_triggers.sql).
    {
      "id" => ->(_) { { id: SecureRandom.uuid } },
      "triage_id" => ->(_) { { triage_id: completed_web_triage_for(citizen).id } },
      # Um cidadão por horário: o mesmo cidadão no mesmo instante é citizen_busy (ADR 0029).
      "appointment_id" => ->(_) { { appointment_id: travel_to(t0) { todays_appointment(person!) }.id } },
      "citizen_id" => ->(_) { { citizen_id: stranger.id } },
      "health_unit_id" => ->(_) { { health_unit_id: other_unit.id } },
      "checked_in_by_user_id" => ->(_) { { checked_in_by_user_id: doctor.id } },
      "checked_in_at" => ->(a) { { checked_in_at: a.checked_in_at - 1.hour } },
      "check_in_method" => ->(_) { { check_in_method: "cpf_exception" } },
      "exception_reason" => ->(_) { { exception_reason: "motivo inventado depois" } },
      "created_at" => ->(a) { { created_at: a.created_at - 1.day } }
    }.each do |column, change|
      it "o banco recusa UPDATE de #{column}, aguardando ou em atendimento" do
        waiting = waiting_attendance(citizen, unit: unit, by: reception)
        in_care = in_care!(waiting_attendance(Citizen.create!(cpf: "93541134780", phone: "+5541933334444"),
                                              unit: unit, by: reception), by: doctor)
        [ waiting, in_care ].each do |a|
          attrs = instance_exec(a, &change)
          expect { attempt { Attendance.where(id: a.id).update_all(attrs) } }
            .to raise_error(ActiveRecord::StatementInvalid, /check-in columns never change/)
        end
      end
    end

    it "a chamada, uma vez gravada, nunca muda (quem e quando), nem ao encerrar" do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      expect { attempt { Attendance.where(id: a.id).update_all(called_at: a.called_at - 1.minute) } }
        .to raise_error(ActiveRecord::StatementInvalid, /call never changes/)
      expect { attempt { Attendance.where(id: a.id).update_all(called_by_user_id: reception.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /call never changes/)
      expect do
        attempt do
          Attendance.where(id: a.id).update_all(status: "closed", outcome: "discharged", closed_by_user_id: doctor.id,
                                                closed_at: Time.current, called_by_user_id: reception.id)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /call never changes/)
    end

    it "atendimento encerrado não muda mais: nenhuma coluna, nem o desfecho, e não se apaga" do
      %w[discharged referred return left].each_with_index do |outcome, i|
        a = closed!(waiting_attendance(Citizen.create!(cpf: %w[11144477735 93541134780 39053344705 71428793860][i],
                                                       phone: "+55419111#{format('%05d', i)}"),
                                       unit: unit, by: reception), outcome: outcome)
        [ { outcome: "discharged", referral_note: nil, referral_unit_id: nil }, { closed_at: a.closed_at + 1.minute },
          { closed_by_user_id: reception.id }, { referral_note: "outra descrição" }, { status: "in_care" } ].each do |attrs|
          expect { attempt { Attendance.where(id: a.id).update_all(attrs) } }
            .to raise_error(ActiveRecord::StatementInvalid, /already closed/), "#{outcome}: #{attrs.keys}"
        end
        expect { attempt { Attendance.where(id: a.id).delete_all } }
          .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      end
    end
  end

  describe "desfecho clínico só a partir de in_care; saiu sem atendimento só a partir de waiting" do
    let(:closing) do
      {
        "discharged" => { outcome: "discharged" },
        "referred" => { outcome: "referred", referral_note: "cardiologia" },
        "return" => { outcome: "return", referral_note: "em duas semanas" }
      }
    end

    it "o banco recusa cada desfecho clínico direto de waiting" do
      a = waiting_attendance(citizen, unit: unit, by: reception)
      closing.each do |outcome, attrs|
        expect do
          attempt do
            Attendance.where(id: a.id).update_all(attrs.merge(status: "closed", closed_by_user_id: doctor.id,
                                                              closed_at: Time.current))
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /invalid transition waiting -> closed/), outcome
      end
    end

    it "o banco recusa left a partir de in_care e aceita left a partir de waiting" do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      expect do
        attempt do
          Attendance.where(id: a.id).update_all(status: "closed", outcome: "left", closed_by_user_id: reception.id,
                                                closed_at: Time.current)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /invalid transition in_care -> closed/)

      w = waiting_attendance(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit, by: reception)
      expect do
        attempt do
          Attendance.where(id: w.id).update_all(status: "closed", outcome: "left", closed_by_user_id: reception.id,
                                                closed_at: Time.current)
        end
      end.not_to raise_error
    end

    it "o banco aceita cada desfecho clínico a partir de in_care" do
      closing.each_with_index do |(outcome, attrs), i|
        a = in_care!(waiting_attendance(Citizen.create!(cpf: %w[11144477735 93541134780 39053344705][i],
                                                        phone: "+55419222#{format('%05d', i)}"),
                                        unit: unit, by: reception), by: doctor)
        expect do
          attempt do
            Attendance.where(id: a.id).update_all(attrs.merge(status: "closed", closed_by_user_id: doctor.id,
                                                              closed_at: Time.current))
          end
        end.not_to raise_error, outcome
      end
    end

    it "o banco recusa voltar de in_care para waiting" do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      expect { attempt { Attendance.where(id: a.id).update_all(status: "waiting", called_at: nil, called_by_user_id: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /call never changes|invalid transition/)
    end
  end

  describe "a exceção por CPF sempre grava método e motivo" do
    it "o banco recusa exceção sem motivo, com motivo curto ou só com espaços (ck_attendances_exception_reason)" do
      [ nil, "curto", "          " ].each do |reason|
        row = fresh_row(check_in_method: "cpf_exception", exception_reason: reason)
        expect { attempt { Attendance.insert_all!([ row ]) } }
          .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_exception_reason/), reason.inspect
      end
    end

    it "o banco recusa motivo num check-in por código (ck_attendances_exception_reason)" do
      row = fresh_row(check_in_method: "code", exception_reason: check_in_reason)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_exception_reason/)
    end

    # ck_attendances_exception_reason só aceita code ou cpf_exception, então
    # também recusa método desconhecido; o Postgres confere os CHECKs em ordem
    # de nome e reporta o primeiro. Os dois existem e os dois recusam.
    it "o banco recusa método desconhecido ou ausente (ck_attendances_method e ck_attendances_exception_reason)" do
      defs = ApplicationRecord.connection.select_rows(<<~SQL).to_h
        SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid = 'attendances'::regclass AND conname IN ('ck_attendances_method', 'ck_attendances_exception_reason')
      SQL
      expect(defs.fetch("ck_attendances_method")).to include("'code'", "'cpf_exception'")
      expect(defs.fetch("ck_attendances_exception_reason")).to include("'code'", "'cpf_exception'")

      [ nil, check_in_reason ].each do |reason|
        row = fresh_row(check_in_method: "balcao", exception_reason: reason)
        expect { attempt { Attendance.insert_all!([ row ]) } }
          .to raise_error(ActiveRecord::CheckViolation, /ck_attendances_(method|exception_reason)/)
      end
      expect { attempt { Attendance.insert_all!([ fresh_row(check_in_method: nil) ]) } }
        .to raise_error(ActiveRecord::NotNullViolation)
    end

    it "o comando grava cpf_exception e o motivo" do
      triage = completed_web_triage_for(citizen)
      a = Attendances::CheckInByException.call(cpf: citizen.cpf, triage_id: triage.id, health_unit_id: unit.id,
                                               reason: "  #{check_in_reason}  ", by: reception).payload.fetch(:attendance)
      expect(a.reload).to have_attributes(check_in_method: "cpf_exception", exception_reason: check_in_reason)
    end
  end

  # Triagens, consentimentos, relatórios e métricas: o check-in, a chamada e o
  # desfecho só acrescentam ao atendimento (mesmo retrato de
  # spec/requests/attendance_contract_spec.rb).
  describe "triages, consentimentos, relatórios e métricas não mudam por check-in, chamada nem desfecho" do
    def snapshot
      {
        triages: Triage.order(:id).map { |t| t.attributes.except("id") },
        consents: Consent.order(:id).map { |c| c.attributes.except("id") },
        report_snapshots: ReportSnapshot.order(:id).map { |r| r.attributes.except("id") },
        dashboard_metrics: DashboardMetric.order(:id).map { |m| m.attributes.except("id") }
      }
    end

    it "percorre código, exceção (triagem e horário), chamar, chamar próximo e cada desfecho" do
      travel_to(t0) do
        others = %w[11144477735 93541134780 39053344705 71428793860].each_with_index.map do |cpf, i|
          Citizen.create!(cpf: cpf, phone: "+55419333#{format('%05d', i)}")
        end
        appt = todays_appointment(others[3])
        triages = [ citizen, *others.first(3) ].map { |c| completed_web_triage_for(c) }
        codes = [ citizen, others[0] ].each_with_index.map do |c, i|
          Citizens::IssueCheckInCode.call(citizen: c, triage: triages[i]).payload.fetch(:code)
        end
        before = snapshot

        by_code = Attendances::CheckIn.call(cpf: citizen.cpf, code: codes[0], health_unit_id: unit.id,
                                            document_checked: true, by: reception).payload.fetch(:attendance)
        by_code2 = Attendances::CheckIn.call(cpf: others[0].cpf, code: codes[1], health_unit_id: unit.id,
                                             document_checked: false, by: reception).payload.fetch(:attendance)
        Attendances::EligibleTriages.call(cpf: others[1].cpf, by: reception, health_unit_id: unit.id)
        by_exception = Attendances::CheckInByException.call(cpf: others[1].cpf, triage_id: triages[2].id,
                                                            health_unit_id: unit.id, reason: check_in_reason,
                                                            by: reception).payload.fetch(:attendance)
        leaving = Attendances::CheckInByException.call(cpf: others[2].cpf, triage_id: triages[3].id,
                                                       health_unit_id: unit.id, reason: check_in_reason,
                                                       by: reception).payload.fetch(:attendance)
        by_slot = Attendances::CheckInByException.call(cpf: others[3].cpf, appointment_id: appt.id,
                                                       health_unit_id: unit.id, reason: check_in_reason,
                                                       by: reception).payload.fetch(:attendance)

        expect(Attendances::Close.call(attendance: leaving, outcome: "left", referral_unit_id: nil,
                                       referral_note: nil, by: reception)).to be_ok
        expect(Attendances::Call.call(attendance: by_code, health_unit_id: unit.id, by: doctor)).to be_ok
        3.times { expect(Attendances::CallNext.call(health_unit_id: unit.id, by: doctor)).to be_ok }
        [ [ by_code, "referred", referral_note ], [ by_code2, "return", return_note ], [ by_exception, "discharged", nil ],
          [ by_slot, "discharged", nil ] ].each do |a, outcome, note|
          expect(Attendances::Close.call(attendance: a.reload, outcome: outcome, referral_unit_id: nil,
                                         referral_note: note, by: doctor)).to be_ok
        end
        expect(Attendance.where(id: [ by_code, by_code2, by_exception, leaving, by_slot ].map(&:id)).pluck(:outcome))
          .to match_array(%w[referred return discharged left discharged])

        expect(snapshot).to eq(before)
      end
    end
  end

  describe "nenhum payload de evento carrega CPF, celular, motivo ou descrição do encaminhamento" do
    it "percorre busca, check-in por código e por exceção, chamar, chamar próximo e cada desfecho" do
      travel_to(t0) do
        others = %w[11144477735 93541134780 39053344705 71428793860].each_with_index.map do |cpf, i|
          Citizen.create!(cpf: cpf, phone: "+55419444#{format('%05d', i)}")
        end
        appt = todays_appointment(others[3])
        triages = [ citizen, *others.first(3) ].map { |c| completed_web_triage_for(c) }
        code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triages[0]).payload.fetch(:code)

        # código com validação do cadastro (citizen.verified)
        by_code = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: true,
                                            by: reception).payload.fetch(:attendance)
        # busca e exceção numa triagem (não só num horário)
        expect(Attendances::EligibleTriages.call(cpf: others[0].cpf, by: reception, health_unit_id: unit.id)).to be_ok
        on_triage = Attendances::CheckInByException.call(cpf: others[0].cpf, triage_id: triages[1].id,
                                                         health_unit_id: unit.id, reason: check_in_reason,
                                                         by: reception).payload.fetch(:attendance)
        leaving = Attendances::CheckInByException.call(cpf: others[1].cpf, triage_id: triages[2].id,
                                                       health_unit_id: unit.id, reason: check_in_reason,
                                                       by: reception).payload.fetch(:attendance)
        on_slot = Attendances::CheckInByException.call(cpf: others[3].cpf, appointment_id: appt.id,
                                                       health_unit_id: unit.id, reason: check_in_reason,
                                                       by: reception).payload.fetch(:attendance)

        expect(Attendances::Close.call(attendance: leaving, outcome: "left", referral_unit_id: nil, referral_note: nil,
                                       by: reception)).to be_ok
        expect(Attendances::Call.call(attendance: by_code, health_unit_id: unit.id, by: doctor)).to be_ok
        2.times { expect(Attendances::CallNext.call(health_unit_id: unit.id, by: doctor)).to be_ok }
        expect(Attendances::Close.call(attendance: by_code.reload, outcome: "referred", referral_unit_id: other_unit.id,
                                       referral_note: referral_note, by: doctor)).to be_ok
        expect(Attendances::Close.call(attendance: on_triage.reload, outcome: "return", referral_unit_id: nil,
                                       referral_note: return_note, by: doctor)).to be_ok
        expect(Attendances::Close.call(attendance: on_slot.reload, outcome: "discharged", referral_unit_id: nil,
                                       referral_note: nil, by: doctor)).to be_ok
      end

      events = DomainEvent.where("name LIKE 'attendance%' OR name LIKE 'appointment%' OR name = 'citizen.verified'").to_a
      expect(events.map(&:name).uniq).to include("attendance.checked_in", "attendance.exception_searched",
                                                 "attendance.called", "attendance.closed", "citizen.verified",
                                                 "appointment.checked_in", "appointment_request.created")
      expect(events.select { |e| e.name == "attendance.closed" }.map { |e| e.payload["outcome"] })
        .to include("left", "referred", "return", "discharged")

      people = [ citizen, *Citizen.where.not(id: citizen.id).to_a ]
      secrets = people.flat_map do |c|
        digits = c.phone.delete("^0-9")
        [ c.cpf, c.cpf_masked, digits, digits.delete_prefix("55"), digits[-9..] ]
      end + [ check_in_reason, referral_note, return_note ]
      forbidden_keys = %w[cpf phone cpf_masked note referral_note exception_reason reason]
      events.each do |event|
        keys = event.payload.keys.map(&:to_s)
        expect(keys & forbidden_keys).to eq([]), "#{event.name} carrega #{keys & forbidden_keys}"
        dump = event.payload.to_json
        secrets.each { |secret| expect(dump).not_to include(secret), "#{event.name} carrega #{secret.inspect}" }
      end
    end
  end

  describe "todo atendimento nasce waiting" do
    it "o banco aceita o nascimento waiting sem chamada nem desfecho" do
      expect { attempt { Attendance.insert_all!([ fresh_row ]) } }.to change(Attendance, :count).by(1)
    end

    it "o banco recusa nascer in_care, mesmo com a chamada coerente" do
      row = fresh_row(status: "in_care", called_by_user_id: doctor.id, called_at: Time.current)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /attendances: born waiting/)
    end

    it "o banco recusa nascer closed, mesmo com o desfecho coerente" do
      row = fresh_row(status: "closed", called_by_user_id: doctor.id, called_at: Time.current, outcome: "discharged",
                      closed_by_user_id: doctor.id, closed_at: Time.current)
      expect { attempt { Attendance.insert_all!([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /attendances: born waiting/)
      left = fresh_row(status: "closed", outcome: "left", closed_by_user_id: reception.id, closed_at: Time.current)
      expect { attempt { Attendance.insert_all!([ left ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /attendances: born waiting/)
    end
  end
end

# O CPF nunca vai na URL (ADR 0018): as rotas de balcão que recebem CPF são só
# POST com corpo JSON. Varre as rotas de /attendance e confere que GET nas
# rotas de CPF responde 404.
RSpec.describe "Invariantes do atendimento: o CPF nunca vai na URL", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:verifier) { staff_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:cpf) { "52998224725" }

  # Os únicos GET de /attendance: nenhum recebe CPF (unidades, fila, pedidos e agenda).
  # erasure_requests lista os pedidos de exclusão pendentes: sem CPF no caminho
  # nem na query, e a lista nunca devolve o CPF. availability (módulo 17) lista
  # vagas e dias livres da unidade por tipo e datas: nenhum dado de cidadão.
  let(:get_allowlist) do
    [ "/attendance/units", "/attendance/units/all", "/attendance/units/:id/queue",
      "/attendance/units/:id/requests", "/attendance/units/:id/agenda", "/attendance/units/:id/availability",
      "/attendance/requests/unassigned", "/attendance/requests/:id", "/attendance/erasure_requests" ]
  end

  def attendance_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      next unless path.start_with?("/attendance")

      [ route.verb, path, route.defaults[:controller], route.defaults[:action] ]
    end
  end

  it "nenhuma rota GET de /attendance é de busca, lookup, check-in ou exceção" do
    gets = attendance_routes.select { |verb, *| verb.include?("GET") }
    expect(gets.map(&:second)).to match_array(get_allowlist)
    expect(gets.map(&:third).uniq).not_to include("check_ins", "attendance")
    expect(attendance_routes.select { |_, path, *| path.match?(/check_ins|lookup|search|exception|verifications/) }
                            .map(&:first).uniq).to eq([ "POST" ])
  end

  %w[/attendance/check_ins /attendance/check_ins/lookup /attendance/check_ins/search /attendance/check_ins/exception
     /attendance/lookup /attendance/verifications /attendance/verifications/search].each do |path|
    it "GET #{path}?cpf=... responde 404" do
      sign_in_as(verifier)
      get path, params: { cpf: cpf, code: "123456" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
