require "rails_helper"

# Módulo 31 (contrato §5, P12, P13, P23, P25, P36; Desvio 1; Review Focus 3;
# preflight, Tabela C 7 → 8): acolhimento noturno — leito exclusivo (409
# bed_taken), uma permanência por paciente (409 already_staying), limite de
# noites com a reavaliação da coordenação, uma ação RAAS por noite no
# fechamento (cada uma no mês da sua noite), o mapa sem nada clínico e o
# detalhe com a trilha. Relógio fixo (meio de novembro, ou o `now:` do exemplo).
RSpec.describe "CAPS — acolhimento noturno", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(example.metadata[:now] || Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(modality: "caps_ad_iii") }
  let(:tech) { caps_staff!(caps, cbo: "322205") }
  let(:lead) { caps_staff!(caps, cbo: "223505", lead: true) }
  let(:l1) { bed!(caps, label: "L1") }
  let(:l2) { bed!(caps, label: "L2") }
  let(:enrollment) { enrollment!(caps, reference: tech, started_on: Date.new(2026, 11, 1)) }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }
  let(:reason) { "Retorno ao convívio familiar combinado com a equipe" }

  def at(day, hour, month: 11) = Time.zone.local(2026, month, day, hour)

  def entry(**over)
    { bed_id: l1.id, enrollment_id: enrollment.id, started_at: at(18, 19).iso8601, expected_end_at: at(19, 8).iso8601 }.merge(over)
  end

  def counts = [ PsychosocialNightStay.count, PsychosocialAction.count, DomainEvent.where("name LIKE 'psychosocial.night%'").count ]

  # Permanência gravada direto (o caminho real é a rota): fechada por padrão.
  def stay!(from, to, bed: l1, of: enrollment, open: false, **extra)
    attrs = { psychosocial_bed: bed, health_unit: caps, psychosocial_enrollment: of, patient_id: of.patient_id, started_at: from,
              expected_end_at: to, started_by_user: tech, **extra }
    attrs.merge!(ended_at: to, end_reason: reason, closed_by_user: tech) unless open
    PsychosocialNightStay.create!(attrs)
  end

  def close_month!(month) = PsychosocialMonthClosure.create!(health_unit: caps, month: month, closed_by_user: lead, closed_at: Time.current)

  before { sign_in_as(tech) }

  describe "POST /psychosocial/night_stays" do
    it "entra no leito: 201 com o detalhe, o evento só com o id, sem trilha" do
      expect { json_post "/psychosocial/night_stays", entry }.to change(PsychosocialNightStay, :count).by(1)
      expect(response).to have_http_status(:created)
      stay = PsychosocialNightStay.find(json_body["id"])
      expect(stay).to have_attributes(psychosocial_bed_id: l1.id, health_unit_id: caps.id, patient_id: enrollment.patient_id,
                                      started_by_user_id: tech.id, reassessment_reason: nil, ended_at: nil)
      expect(json_body).to include("bed" => Psychosocial::Json.bed(l1), "enrollment_id" => enrollment.id,
                                   "patient" => Psychosocial::Json.patient_ref(enrollment.patient),
                                   "started_at" => at(18, 19).iso8601, "expected_end_at" => at(19, 8).iso8601,
                                   "nights" => [ "2026-11-18" ], "reassessment" => nil, "ended_at" => nil,
                                   "started_by" => Psychosocial::Json.pro(tech, "322205"))
      expect(DomainEvent.where(name: "psychosocial.night_stay_started").last.payload).to eq("night_stay_id" => stay.id)
      expect(viewed.count).to eq(0)
    end

    it "leito ocupado → 409 bed_taken; paciente já no L1 entrando no L2 → 409 already_staying; nada gravado" do
      json_post "/psychosocial/night_stays", entry
      other = enrollment!(caps, reference: tech, started_on: Date.new(2026, 11, 1))
      expect { json_post "/psychosocial/night_stays", entry(enrollment_id: other.id) }.not_to(change { counts })
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "bed_taken" } ])

      expect { json_post "/psychosocial/night_stays", entry(bed_id: l2.id) }.not_to(change { counts })
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_staying" } ])
    end

    it "leito livre de novo depois da saída; entrada que cruza uma permanência já fechada → bed_taken" do
      stay!(at(10, 19), at(12, 8))
      json_post "/psychosocial/night_stays", entry(started_at: at(11, 19).iso8601)
      expect([ response.status, json_body["error"] ]).to eq([ 409, "bed_taken" ])
      json_post "/psychosocial/night_stays", entry
      expect(response).to have_http_status(:created)
    end

    it "a 15ª noite no AD III → 422 night_limit_reached para a técnica; a coordenação passa com a reavaliação" do
      stay!(at(1, 19), at(15, 8), bed: l2) # noites 1..14
      expect { json_post "/psychosocial/night_stays", entry }.not_to(change { counts })
      expect([ response.status, json_body ])
        .to eq([ 422, { "error" => "night_limit_reached", "used" => 15, "limit" => 14, "window_days" => 30, "rule" => "total" } ])
      json_post "/psychosocial/night_stays", entry(reassessment: { reason: "Risco de recaída na semana" })
      expect(json_body["error"]).to eq("night_limit_reached")

      sign_in_as(lead)
      json_post "/psychosocial/night_stays", entry
      expect(json_body["error"]).to eq("night_limit_reached")
      json_post "/psychosocial/night_stays", entry(reassessment: { reason: "curto" })
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "reassessment.reason" ])

      json_post "/psychosocial/night_stays", entry(reassessment: { reason: " Risco de recaída na semana de festas " })
      expect(response).to have_http_status(:created)
      stay = PsychosocialNightStay.find(json_body["id"])
      expect(stay).to have_attributes(reassessment_reason: "Risco de recaída na semana de festas", reassessed_by_user_id: lead.id)
      expect(json_body["reassessment"]).to eq("reason" => "Risco de recaída na semana de festas",
                                              "by" => Psychosocial::Json.pro(lead, "223505"))
      expect(DomainEvent.where(name: "psychosocial.night_limit_overridden").map(&:payload)).to eq([ { "night_stay_id" => stay.id } ])
    end

    it "abaixo do limite a reavaliação não é gravada nem publicada" do
      sign_in_as(lead)
      json_post "/psychosocial/night_stays", entry(reassessment: { reason: "Risco de recaída na semana" })
      expect(response).to have_http_status(:created)
      expect(PsychosocialNightStay.find(json_body["id"]).reassessment_reason).to be_nil
      expect(DomainEvent.where(name: "psychosocial.night_limit_overridden")).to be_empty
    end

    it "matrícula de outro CAPS, encerrada ou iniciada depois da entrada → 422 enrollment_required em enrollment_id" do
      foreign = enrollment!(caps!(modality: "caps_ad_iii"))
      later = enrollment!(caps, reference: tech, started_on: Date.new(2026, 11, 19))
      closed = enrollment!(caps, reference: tech, started_on: Date.new(2026, 11, 1))
      closed.update_columns(closed_on: Date.new(2026, 11, 17), destination: "01", closed_by_user_id: tech.id)
      [ foreign, later, closed ].each do |other|
        expect { json_post "/psychosocial/night_stays", entry(enrollment_id: other.id) }.not_to(change { counts })
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "enrollment_required", "enrollment_id" ])
      end
    end

    it "recusas de campo de uma vez: início a mais de 12 h, saída prevista acima de 30 dias, chave desconhecida" do
      json_post "/psychosocial/night_stays", entry(started_at: at(19, 4).iso8601, expected_end_at: at(20, 8).iso8601)
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "started_at" } ])
      json_post "/psychosocial/night_stays", entry(expected_end_at: at(19, 8, month: 12).iso8601, cid: "F10")
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "cid" },
                                            { "error" => "invalid_request", "path" => "expected_end_at" } ])
      json_post "/psychosocial/night_stays", entry(expected_end_at: at(18, 18).iso8601)
      expect(json_body["path"]).to eq("expected_end_at")
      expect(PsychosocialNightStay.count).to eq(0)
    end

    it "ids que não são texto (número, lista, objeto) → 422 invalid_request, nunca 500" do
      [ 123, [ enrollment.id ], { id: enrollment.id } ].each do |value|
        json_post "/psychosocial/night_stays", entry(enrollment_id: value)
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "enrollment_id" ])
        json_post "/psychosocial/night_stays", entry(bed_id: value)
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "bed_id" ])
      end
      expect(PsychosocialNightStay.count).to eq(0)
    end

    it "entrada em mês fechado → 422 month_closed em started_at" do
      stay_enrollment = enrollment!(caps, reference: tech, started_on: Date.new(2026, 10, 1))
      close_month!(Date.new(2026, 10, 1))
      json_post "/psychosocial/night_stays", entry(enrollment_id: stay_enrollment.id, started_at: at(30, 19, month: 10).iso8601,
                                                   expected_end_at: at(31, 8, month: 10).iso8601)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "started_at" ])
    end

    it "leito de CAPS sem noturno → caps_without_beds; equipe de outro CAPS → not_on_caps_team; sem o papel → missing_role" do
      caps_ii = caps!(modality: "caps_ii")
      # O cadastro recusa leito em CAPS II; um leito antigo (de quando era AD III) fica no banco.
      old_bed = PsychosocialBed.create!(health_unit: caps_ii, label: "L1", updated_by_user: psychosocial_admin!)
      sign_in_as(caps_staff!(caps_ii))
      json_post "/psychosocial/night_stays", entry(bed_id: old_bed.id)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "caps_without_beds", "bed_id" ])

      json_post "/psychosocial/night_stays", entry
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_on_caps_team" } ])
      sign_in_as(psychosocial_admin!)
      json_post "/psychosocial/night_stays", entry
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  describe "a rede do banco (a corrida que o Ruby não vê)" do
    # O Ruby confere antes; aqui a conferência é desligada para provar que a
    # exclusion do leito e o índice do paciente viram 409, não 500.
    before { allow(Psychosocial::StartNightStay).to receive(:conflict).and_return(nil) }

    it "exclusion do leito → bed_taken; índice da permanência aberta do paciente → already_staying" do
      stay!(at(17, 19), at(19, 8), open: true, of: enrollment!(caps, reference: tech, started_on: Date.new(2026, 11, 1)))
      json_post "/psychosocial/night_stays", entry
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "bed_taken" } ])

      stay!(at(17, 19), at(19, 8), bed: l2, open: true)
      json_post "/psychosocial/night_stays", entry(bed_id: bed!(caps, label: "L3").id)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_staying" } ])
    end
  end

  describe "POST /psychosocial/night_stays/:id/close" do
    it "3 noites → 3 ações 0301080020 (quantidade 1, 20:00 locais, origin night_stay) por quem fecha; a trilha do detalhe" do
      stay = stay!(at(15, 19), at(18, 8), open: true)
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 8).iso8601, reason: reason
      expect(response).to have_http_status(:ok)
      expect(stay.reload).to have_attributes(ended_at: at(18, 8), end_reason: reason, closed_by_user_id: tech.id)
      actions = PsychosocialAction.where(psychosocial_night_stay_id: stay.id).order(:performed_at)
      expect(actions.map { |a| [ a.sigtap_code, a.quantity, a.performed_at, a.month, a.origin, a.instrument, a.professional_user_id ] })
        .to eq((15..17).map { |d| [ "0301080020", 1, at(d, 20), Date.new(2026, 11, 1), "night_stay", "raas_psi", tech.id ] })
      expect(actions.map { |a| a.psychosocial_action_participants.sole.psychosocial_enrollment_id }.uniq).to eq([ enrollment.id ])
      expect(json_body).to include("ended_at" => at(18, 8).iso8601, "end_reason" => reason, "nights" => %w[2026-11-15 2026-11-16 2026-11-17],
                                   "closed_by" => Psychosocial::Json.pro(tech, "322205"))
      expect(DomainEvent.where(name: "psychosocial.night_stay_closed").last.payload).to eq("night_stay_id" => stay.id)
      expect(viewed.last.payload).to include("patient_id" => enrollment.patient_id, "access" => "psychosocial", "resource" => "night_stay")

      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 9).iso8601, reason: reason
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_closed" } ])
    end

    it "Review Focus 3: a permanência atravessa a virada do mês; cada ação cai no mês da sua noite", now: Time.zone.local(2026, 12, 2, 10, 0) do
      stay = stay!(at(29, 19), at(2, 8, month: 12), open: true)
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(2, 8, month: 12).iso8601, reason: reason
      expect(response).to have_http_status(:ok)
      actions = PsychosocialAction.where(psychosocial_night_stay_id: stay.id).order(:performed_at)
      # 20:00 de 30/11 local é 23:00 UTC de 30/11; a noite de 01/12 é de dezembro.
      expect(actions.map { |a| [ a.performed_at, a.month ] }).to eq([ [ at(29, 20), Date.new(2026, 11, 1) ],
                                                                     [ at(30, 20), Date.new(2026, 11, 1) ],
                                                                     [ at(1, 20, month: 12), Date.new(2026, 12, 1) ] ])
      expect(PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: enrollment.id).order(:month).pluck(:month))
        .to eq([ Date.new(2026, 11, 1), Date.new(2026, 12, 1) ])
      expect(PsychosocialMonthClosure.count).to eq(0)
    end

    it "uma noite em mês fechado → 422 month_closed e nada fecha", now: Time.zone.local(2026, 12, 2, 10, 0) do
      stay = stay!(at(29, 19), at(2, 8, month: 12), open: true)
      close_month!(Date.new(2026, 11, 1))
      expect do
        json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(2, 8, month: 12).iso8601, reason: reason
      end.not_to(change { counts })
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "ended_at" ])
      expect(stay.reload).to be_open
    end

    it "só a última noite recusada pela crítica: as ações das noites anteriores são desfeitas e a permanência segue aberta",
       now: Time.zone.local(2026, 12, 2, 10, 0) do
      # A SIGTAP de 202612 sem o código noturno: 29 e 30/11 passam, 01/12 é recusada.
      allow_any_instance_of(Billing::SigtapCache).to receive(:procedure).and_wrap_original do |original, release, code|
        release.version == "202612" && code == "0301080020" ? nil : original.call(release, code)
      end
      stay = stay!(at(29, 19), at(2, 8, month: 12), open: true)
      expect do
        json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(2, 8, month: 12).iso8601, reason: reason
      end.not_to(change { [ *counts, PsychosocialMonthlyRecord.count, DomainEvent.where(name: "psychosocial.action_recorded").count ] })
      expect([ response.status, json_body ])
        .to eq([ 422, { "error" => "action_rejected", "problems" => [ { "error" => "instrument_mismatch", "path" => "sigtap_code" } ] } ])
      expect(PsychosocialAction.where(psychosocial_night_stay_id: stay.id)).to be_empty
      expect(stay.reload).to be_open
    end

    it "entrada às 23:30 de 30/11 local (02:30 UTC de 01/12) e saída em 01/12: a ação da noite fica em novembro",
       now: Time.zone.local(2026, 12, 1, 10, 0) do
      json_post "/psychosocial/night_stays", entry(started_at: Time.zone.local(2026, 11, 30, 23, 30).iso8601,
                                                   expected_end_at: at(1, 8, month: 12).iso8601)
      expect(response).to have_http_status(:created)
      json_post "/psychosocial/night_stays/#{json_body["id"]}/close", ended_at: at(1, 8, month: 12).iso8601, reason: reason
      expect(response).to have_http_status(:ok)
      action = PsychosocialAction.where(psychosocial_night_stay_id: json_body["id"]).sole
      expect([ action.performed_at, action.month ]).to eq([ Time.zone.local(2026, 11, 30, 23, 30), Date.new(2026, 11, 1) ])
      expect(action.performed_at.utc.to_date).to eq(Date.new(2026, 12, 1))
    end

    describe "noite repetida" do
      let(:night) { ->(stay) { PsychosocialAction.where(psychosocial_night_stay_id: stay.id).map { |a| a.performed_at.to_date } } }
      let!(:first) { stay!(at(14, 19), at(14, 22), open: true) } # noite 14, saída na mesma noite

      before do
        json_post "/psychosocial/night_stays/#{first.id}/close", ended_at: at(14, 22).iso8601, reason: reason
        expect(night.call(first)).to eq([ Date.new(2026, 11, 14) ])
      end

      it "a data que já tem ação noturna não cancelada do paciente no CAPS não gera outra" do
        second = stay!(at(14, 23), at(16, 8), bed: l2, open: true) # noites 14 e 15
        json_post "/psychosocial/night_stays/#{second.id}/close", ended_at: at(16, 8).iso8601, reason: reason
        expect(response).to have_http_status(:ok)
        expect(night.call(second)).to eq([ Date.new(2026, 11, 15) ])
      end

      it "a ação cancelada da noite não conta: a noite volta a gerar ação" do
        Psychosocial::CancelAction.call(action: PsychosocialAction.find_by!(psychosocial_night_stay_id: first.id),
                                        reason: "Registro em duplicidade da noite", by: tech)
        second = stay!(at(14, 23), at(15, 8), bed: l2, open: true) # noite 14
        json_post "/psychosocial/night_stays/#{second.id}/close", ended_at: at(15, 8).iso8601, reason: reason
        expect(night.call(second)).to eq([ Date.new(2026, 11, 14) ])
      end
    end

    it "crítica recusa a noite (CBO de quem fecha fora da lista) → 422 action_rejected e nada fecha" do
      stay = stay!(at(15, 19), at(18, 8), open: true)
      sign_in_as(caps_staff!(caps, cbo: "515105"))
      expect do
        json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 8).iso8601, reason: reason
      end.not_to(change { counts })
      expect([ response.status, json_body ])
        .to eq([ 422, { "error" => "action_rejected", "problems" => [ { "error" => "cbo_incompatible", "path" => "sigtap_code" } ] } ])
      expect(stay.reload).to be_open
    end

    it "noites reais acima do limite: a técnica não fecha; a coordenação fecha gravando a reavaliação junto" do
      stay!(at(1, 19), at(13, 8), bed: l2) # noites 1..12
      stay = stay!(at(15, 19), at(16, 8), open: true) # prevista: 1 noite (13ª); real: 15, 16, 17 (15 noites)
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 8).iso8601, reason: reason
      expect([ response.status, json_body ])
        .to eq([ 422, { "error" => "night_limit_reached", "used" => 15, "limit" => 14, "window_days" => 30, "rule" => "total" } ])
      expect(stay.reload).to be_open

      sign_in_as(lead)
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 8).iso8601, reason: reason,
                                                               reassessment: { reason: "Crise prolongada, sem rede de apoio" }
      expect(response).to have_http_status(:ok)
      expect(stay.reload).to have_attributes(reassessment_reason: "Crise prolongada, sem rede de apoio", reassessed_by_user_id: lead.id,
                                             closed_by_user_id: lead.id)
      expect(PsychosocialAction.where(psychosocial_night_stay_id: stay.id).count).to eq(3)
      expect(DomainEvent.where(name: "psychosocial.night_limit_overridden").map(&:payload)).to eq([ { "night_stay_id" => stay.id } ])
    end

    it "reavaliada na entrada: a saída não confere o limite de novo" do
      stay!(at(1, 19), at(15, 8), bed: l2) # noites 1..14
      stay = stay!(at(15, 19), at(16, 8), open: true, reassessment_reason: "Risco de recaída na semana", reassessed_by_user: lead)
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 8).iso8601, reason: reason
      expect(response).to have_http_status(:ok)
      expect(stay.reload.reassessment_reason).to eq("Risco de recaída na semana")
    end

    it "recusas de campo: saída antes da entrada ou no futuro, motivo curto; chave desconhecida" do
      stay = stay!(at(15, 19), at(18, 8), open: true)
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(15, 18).iso8601, reason: "curto"
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "ended_at" },
                                            { "error" => "invalid_request", "path" => "reason" } ])
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 16).iso8601, reason: "x" * 501
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "ended_at" },
                                            { "error" => "too_long", "path" => "reason" } ])
      json_post "/psychosocial/night_stays/#{stay.id}/close", ended_at: at(18, 8).iso8601, reason: reason, bed_id: l2.id
      expect([ response.status, json_body["path"] ]).to eq([ 422, "bed_id" ])
      expect(stay.reload).to be_open
    end
  end

  describe "GET /psychosocial/night_stays/:id" do
    it "detalhe com a trilha `night_stay`; de outro CAPS → 404 sem trilha" do
      stay = stay!(at(15, 19), at(18, 8))
      expect { get "/psychosocial/night_stays/#{stay.id}" }.to change { viewed.count }.by(1)
      expect(json_body).to include("id" => stay.id, "end_reason" => reason, "nights" => %w[2026-11-15 2026-11-16 2026-11-17])
      expect(viewed.last.payload).to include("patient_id" => enrollment.patient_id, "user_id" => tech.id, "resource" => "night_stay")

      sign_in_as(caps_staff!(caps!(modality: "caps_ad_iii")))
      expect { get "/psychosocial/night_stays/#{stay.id}" }.not_to(change { viewed.count })
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /psychosocial/beds/board" do
    it "leitos ativos por rótulo, o ocupante só como <patient-ref>, as noites usadas na janela e o limite; sem trilha" do
      stay!(at(1, 19), at(4, 8), bed: l2) # noites 1..3
      occupied = stay!(at(16, 19), at(20, 8), bed: l2, open: true) # 16..19
      l1
      PsychosocialBed.create!(health_unit: caps, label: "L9", active: false, updated_by_user: psychosocial_admin!)
      expect { get "/psychosocial/beds/board", params: { health_unit_id: caps.id, date: "2026-11-18" } }.not_to(change { viewed.count })
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(
        "date" => "2026-11-18", "window_days" => 30,
        "items" => [
          { "bed" => Psychosocial::Json.bed(l1), "stay" => nil, "nights_used" => nil, "limit" => nil },
          { "bed" => Psychosocial::Json.bed(l2),
            "stay" => { "id" => occupied.id, "patient" => Psychosocial::Json.patient_ref(enrollment.patient),
                        "started_at" => at(16, 19).iso8601, "expected_end_at" => at(20, 8).iso8601 },
            "nights_used" => 6, "limit" => 14 }
        ]
      )
      expect(json_body.dig("items", 1, "stay", "patient").keys).to eq(%w[patient_id name cns_masked])
      expect(response.body).not_to include(enrollment.cid_main)

      get "/psychosocial/beds/board", params: { health_unit_id: caps.id, date: "2026-11-02" }
      expect(json_body["items"].map { |item| item["stay"]&.dig("id") }).to eq([ nil, PsychosocialNightStay.where(started_at: at(1, 19)).sole.id ])
      get "/psychosocial/beds/board", params: { health_unit_id: caps.id, date: "2026-11-04" }
      expect(json_body["items"].map { |item| item["stay"] }).to eq([ nil, nil ])
    end

    it "sem `date`, hoje; CAPS II → caps_without_beds; data inválida, outro CAPS e o administrador recusados" do
      l1
      get "/psychosocial/beds/board", params: { health_unit_id: caps.id }
      expect(json_body["date"]).to eq("2026-11-18")
      get "/psychosocial/beds/board", params: { health_unit_id: caps.id, date: "18/11/2026" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "date" ])
      get "/psychosocial/beds/board", params: { health_unit_id: caps.id, q: "Maria" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "q" ])

      caps_ii = caps!(modality: "caps_ii")
      sign_in_as(caps_staff!(caps_ii))
      get "/psychosocial/beds/board", params: { health_unit_id: caps_ii.id }
      expect([ response.status, json_body["error"] ]).to eq([ 422, "caps_without_beds" ])
      get "/psychosocial/beds/board", params: { health_unit_id: caps.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_on_caps_team" } ])
      sign_in_as(psychosocial_admin!)
      get "/psychosocial/beds/board", params: { health_unit_id: caps.id }
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end
end
