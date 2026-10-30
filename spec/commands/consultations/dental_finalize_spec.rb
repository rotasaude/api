require "rails_helper"

# Módulo 28 (ADR 0046; contrato §4, §6, §16 O2, O6, O7, O8, O22, O26; Desvios
# 2, 7, 8, 10): finalizar a consulta odontológica. Todas as recusas de uma vez
# em `problems`, nada gravado; ao finalizar, procedimentos → eventos do
# odontograma (achados e efeitos SIGTAP, em ordem de gravação) → plano da
# unidade → registro periodontal → periograma → endodontia. Review Focus 3:
# dois planos do mesmo paciente (UBS e CEO).
RSpec.describe Consultations::Finalize do
  before { Current.city = dental_city! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1) }

  def start(by: dentist, at: unit, who: citizen, baseline: false) = dental_consultation!(unit: at, by: by, citizen: who, baseline: baseline)

  def draft!(consultation, params = nil, by: consultation.author_user, **over)
    saved = Consultations::SaveDraft.call(consultation: consultation, params: params || dental_body(**over), by: by)
    raise "rascunho recusado: #{saved.reason} #{saved.details}" if saved.failure?

    consultation
  end

  def finalize(consultation, outcome: { "outcome" => "discharged" })
    described_class.call(consultation: consultation.reload, outcome_params: outcome, by: consultation.author_user)
  end

  def problems(result) = result.details[:problems].map { |p| [ p[:error], p[:path] ] }
  def errors(result) = result.details[:problems].map { |p| p[:error] }

  def done!(consultation, outcome: { "outcome" => "discharged" })
    result = finalize(consultation, outcome: outcome)
    raise "finalização recusada: #{result.reason} #{result.details}" if result.failure?

    consultation.reload
  end

  def restoration(tooth, face = nil, **extra)
    location = face ? { "kind" => "face", "tooth" => tooth, "face" => face } : { "kind" => "tooth", "tooth" => tooth }
    { "sigtap" => "0307010031", "location" => location }.merge(extra.transform_keys(&:to_s))
  end

  def plan_of(health_unit) = DentalTreatmentPlan.find_by(health_unit: health_unit, patient_id: Patients::Resolve.call(citizen).payload[:patient].id)

  it "recusas juntas: vigilância, tipo de consulta, concluído sem tipo e gestante; nada gravado" do
    consultation = draft!(start, dental: { "oral_health_surveillance" => [], "care_type" => 2, "dental_consultation_type" => nil,
                                           "dental_outcomes" => [ 15, 17 ], "pregnant" => nil })
    result = finalize(consultation)
    expect(result).to be_failure
    expect(problems(result)).to include([ "oral_health_surveillance_required", "dental.oral_health_surveillance" ],
                                        [ "dental_consultation_type_required", "dental.dental_consultation_type" ],
                                        [ "completed_requires_first_or_return", "dental.dental_outcomes[0]" ],
                                        [ "pregnant_required", "dental.pregnant" ])
    expect([ result.reason, result.details[:path] ]).to eq([ result.details[:problems].first[:error].to_sym, result.details[:problems].first[:path] ])
    expect(consultation.reload.status).to eq("draft")
    expect([ DentalProcedure.count, DentalChartEvent.count, DentalTreatmentPlan.count, PatientProblem.count ]).to eq([ 0, 0, 0, 0 ])
    expect(consultation.attendance.reload.status).to eq("in_care")
  end

  it "regras do tipo, da gestante, do problema e do desfecho, cada uma com o seu código" do
    consultation = start
    {
      { "care_type" => 4, "dental_consultation_type" => 1 } => "dental_consultation_type_forbidden",
      { "care_type" => 6, "dental_consultation_type" => 2 } => "return_forbidden_on_urgency",
      { "dental_consultation_type" => 1, "dental_outcomes" => [ 17 ] } => "discharge_forbidden_with_first_or_return",
      { "dental_outcomes" => [] } => "dental_outcome_required",
      { "care_type" => nil } => "care_type_required"
    }.each do |dental, error|
      draft!(consultation, dental: dental)
      expect(errors(finalize(consultation))).to eq([ error ]), "#{dental} → #{error}"
    end
    draft!(consultation, evaluated_problems: [])
    expect(errors(finalize(consultation))).to eq([ "problem_required" ])
    draft!(consultation, assessment: nil)
    expect(errors(finalize(consultation))).to eq([ "assessment_or_plan_required" ])

    male = start(who: verified_citizen!(2, sex: "male"))
    draft!(male, dental: { "pregnant" => true })
    expect(problems(finalize(male))).to eq([ [ "pregnant_forbidden_male", "dental.pregnant" ] ])
  end

  it "três restaurações nas faces do 11, 12 e 21 → 3 procedimentos e 3 eventos restored nas faces; o achado da mesma face vem antes" do
    consultation = draft!(start, dental: { "procedures" => [ restoration(11, "M"), restoration(12, "D"), restoration(21, "V") ],
                                           "findings" => [ { "tooth" => 11, "face" => "M", "situation" => "caries" } ] })
    done!(consultation)
    expect(consultation.dental_procedures.pluck(:procedure_code, :location_kind, :tooth, :face, :quantity))
      .to match_array([ [ "0307010031", "face", 11, "M", 1 ], [ "0307010031", "face", 12, "D", 1 ], [ "0307010031", "face", 21, "V", 1 ] ])
    restored = consultation.dental_chart_events.where(situation: "restored")
    expect(restored.pluck(:tooth, :face, :part)).to match_array([ [ 11, "M", "crown" ], [ 12, "D", "crown" ], [ 21, "V", "crown" ] ])
    expect(restored.pluck(:procedure_code).uniq).to eq([ "0307010031" ])
    expect(restored.where.not(dental_procedure_id: nil).count).to eq(3)
    expect(consultation.dental_chart_events.pluck(:cbo_code, :author_user_id).uniq).to eq([ [ "223208", dentist.id ] ])
    chart = DentalCare::Chart.call(consultation.patient)
    expect(chart[:teeth].find { |t| t[:tooth] == 11 }[:faces]["M"]).to eq("restored")
  end

  it "33 exodontias somadas → quantity_exceeds_location_limit com o SIGTAP" do
    teeth = DentalCare::Catalog::PERMANENT_TEETH + [ 11 ]
    exodontias = teeth.map { |tooth| { "sigtap" => "0414020138", "location" => { "kind" => "tooth", "tooth" => tooth } } }
    consultation = draft!(start, dental: { "procedures" => exodontias })
    result = finalize(consultation)
    expect(result.details[:problems]).to eq([ { path: "dental.procedures", error: "quantity_exceeds_location_limit", sigtap: "0414020138" } ])
    expect(DentalProcedure.count).to eq(0)
  end

  describe "TSB/ASB (Desvio 8)" do
    let(:auxiliary) { auxiliary!(unit) }

    it "fora da lista, encaminhamento e plano recusados; baixa de item com SIGTAP da lista → done" do
      sealant = { "sigtap" => "0101020066", "location" => { "kind" => "tooth", "tooth" => 16 } }
      first = done!(draft!(start, dental: { "plan_changes" => { "add" => [ sealant ] } }))
      item = plan_of(unit).items.sole
      expect(item).to have_attributes(status: "planned", added_in_consultation_id: first.id)

      consultation = draft!(start(by: auxiliary), dental: { "procedures" => [ restoration(11) ], "dental_outcomes" => [ 3 ],
                                                             "plan_changes" => { "add" => [ sealant ] } })
      expect(problems(finalize(consultation))).to include([ "auxiliary_procedure_not_allowed", "dental.procedures[0].sigtap" ],
                                                          [ "auxiliary_cannot_refer", "dental.dental_outcomes[0]" ],
                                                          [ "auxiliary_cannot_plan", "dental.plan_changes" ])
      draft!(consultation, dental: { "procedures" => [ sealant.merge("plan_item_id" => item.id) ], "dental_outcomes" => [ 16 ],
                                     "plan_changes" => { "add" => [] } })
      done!(consultation)
      expect(item.reload).to have_attributes(status: "done", done_in_consultation_id: consultation.id)
      expect(consultation.dental_procedures.sole.dental_treatment_plan_item_id).to eq(item.id)
    end

    it "o auxiliar nunca abre plano nem o conclui: primeira programática sem plano; desfecho 15 → auxiliary_cannot_plan" do
      first = done!(draft!(start(by: auxiliary), dental: { "procedures" => [] }))
      expect(first.dental_consultation_type).to eq(1)
      expect(DentalTreatmentPlan.count).to eq(0)
      done!(draft!(start, dental: { "plan_changes" => { "add" => [ restoration(21) ] } }))
      consultation = draft!(start(by: auxiliary), dental: { "procedures" => [], "dental_consultation_type" => 2, "dental_outcomes" => [ 15 ] })
      expect(problems(finalize(consultation))).to eq([ [ "auxiliary_cannot_plan", "dental.dental_outcomes[0]" ] ])
      expect(plan_of(unit).reload.status).to eq("open")
    end

    it "periograma e endodontia do auxiliar recusados" do
      consultation = draft!(start(by: auxiliary), dental: { "procedures" => [],
                                                             "periodontal_chart" => { "teeth" => [ { "tooth" => 16, "sites" => [] } ] },
                                                             "endodontics" => [ { "tooth" => 11, "canals" => 1, "status" => "in_progress" } ] })
      expect(problems(finalize(consultation))).to include([ "auxiliary_procedure_not_allowed", "dental.periodontal_chart" ],
                                                          [ "auxiliary_procedure_not_allowed", "dental.endodontics" ])
    end
  end

  describe "plano de tratamento (Desvio 7)" do
    it "primeira programática na UBS abre o plano; a seguinte dá baixa nos dois; o 15 fecha com o evento" do
      first = done!(draft!(start, dental: { "plan_changes" => { "add" => [ restoration(21), restoration(22) ] } }))
      plan = plan_of(unit)
      expect(plan).to have_attributes(status: "open", opened_in_consultation_id: first.id)
      expect(plan.items.pluck(:status)).to eq(%w[planned planned])
      expect(first.dental_procedures.count).to eq(1)

      items = plan.items.order(:tooth).to_a
      second = draft!(start, dental: { "dental_consultation_type" => 2,
                                       "procedures" => items.map { |i| restoration(i.tooth, plan_item_id: i.id) } })
      expect(DentalCare::Plans.suggest_completed?(second)).to be(true)
      expect(Consultations::Json.consultation(second)[:dental]).to include(suggest_completed: true)
      draft!(second, dental: { "dental_consultation_type" => 2, "dental_outcomes" => [ 15 ],
                               "procedures" => items.map { |i| restoration(i.tooth, plan_item_id: i.id) } })
      done!(second)
      expect(plan.reload).to have_attributes(status: "completed", closed_in_consultation_id: second.id, closed_by_user_id: dentist.id)
      expect(plan.items.pluck(:status)).to eq(%w[done done])
      expect(DomainEvent.where(name: "dental_plan.completed").sole.payload).to eq("plan_id" => plan.id, "consultation_id" => second.id)
      expect(Consultations::Json.consultation(second.reload)[:dental]).to include(suggest_completed: false)
    end

    it "sem plano aberto: acrescentar item em consulta de retorno → plan_requires_first_consultation" do
      consultation = draft!(start, dental: { "dental_consultation_type" => 2, "plan_changes" => { "add" => [ restoration(21) ] } })
      expect(problems(finalize(consultation))).to eq([ [ "plan_requires_first_consultation", "dental.plan_changes.add" ] ])
    end

    it "cancelamento de item e do plano inteiro, com motivo; dental_plan.cancelled só com ids" do
      done!(draft!(start, dental: { "plan_changes" => { "add" => [ restoration(21), restoration(22) ] } }))
      plan = plan_of(unit)
      item = plan.items.order(:tooth).first
      consultation = draft!(start, dental: { "dental_consultation_type" => 2,
                                             "plan_changes" => { "cancel" => [ { "item_id" => item.id, "reason" => "Dente com indicação de exodontia" } ],
                                                                 "cancel_plan" => { "reason" => "Paciente mudou de município" } } })
      done!(consultation)
      expect(item.reload).to have_attributes(status: "cancelled", cancelled_in_consultation_id: consultation.id,
                                             cancel_reason: "Dente com indicação de exodontia")
      expect(plan.reload).to have_attributes(status: "cancelled", cancel_reason: "Paciente mudou de município",
                                             closed_in_consultation_id: consultation.id)
      # O31: o item que ficou previsto cai com o plano, com o motivo dele.
      expect(plan.items.order(:tooth).last).to have_attributes(status: "cancelled", cancel_reason: "Paciente mudou de município",
                                                               cancelled_in_consultation_id: consultation.id)
      expect(DomainEvent.where(name: "dental_plan.cancelled").sole.payload).to eq("plan_id" => plan.id, "consultation_id" => consultation.id)
    end
  end

  it "Review Focus 3: dois planos (UBS e CEO); o item da UBS não baixa no CEO; o 15 do CEO fecha só o do CEO" do
    done!(draft!(start, dental: { "plan_changes" => { "add" => [ restoration(21) ] } }))
    ubs_plan = plan_of(unit)
    ubs_item = ubs_plan.items.sole
    ceo = ceo_unit!
    endodontist = dentist!(ceo, cbo: "223212")
    endo = ->(**extra) { { "sigtap" => "0307020061", "location" => { "kind" => "tooth", "tooth" => 21 } }.merge(extra.transform_keys(&:to_s)) }

    first_ceo = draft!(start(by: endodontist, at: ceo), dental: { "dental_consultation_type" => 2,
                                                                  "procedures" => [ restoration(21, plan_item_id: ubs_item.id) ] })
    expect(problems(finalize(first_ceo))).to eq([ [ "plan_item_not_open", "dental.procedures[0].plan_item_id" ] ])
    draft!(first_ceo, dental: { "dental_consultation_type" => 2, "procedures" => [], "plan_changes" => { "add" => [ endo.() ] } })
    done!(first_ceo)
    ceo_plan = plan_of(ceo)
    expect(ceo_plan).to have_attributes(status: "open", opened_in_consultation_id: first_ceo.id)
    expect(ceo_plan.id).not_to eq(ubs_plan.id)

    second_ceo = draft!(start(by: endodontist, at: ceo),
                        dental: { "dental_consultation_type" => 2, "procedures" => [ endo.(plan_item_id: ceo_plan.items.sole.id) ] })
    expect(DentalCare::Plans.suggest_completed?(second_ceo)).to be(true)
    draft!(second_ceo, dental: { "dental_consultation_type" => 2, "dental_outcomes" => [ 15 ],
                                 "procedures" => [ endo.(plan_item_id: ceo_plan.items.sole.id) ] })
    done!(second_ceo)
    expect(ceo_plan.reload.status).to eq("completed")
    expect(ubs_plan.reload.status).to eq("open")
    expect(ubs_item.reload.status).to eq("planned")
  end

  it "id de procedimento já gravado: o rascunho recusa; o que escapou ao rascunho é recusado na finalização, nunca 500" do
    taken = done!(draft!(start)).dental_procedures.sole.id
    consultation = start
    refused = Consultations::SaveDraft.call(consultation: consultation, by: dentist,
                                            params: { "dental" => { "procedures" => [ restoration(11, id: taken) ] } })
    expect([ refused.reason, refused.details ]).to eq([ :invalid_request, { path: "dental.procedures[0].id" } ])
    draft!(consultation)
    items = consultation.reload.draft_items
    items["dental"]["procedures"][0]["id"] = taken
    consultation.update_columns(draft_items: items)
    expect(problems(finalize(consultation))).to eq([ [ "invalid_request", "dental.procedures[0].id" ] ])
  end

  it "O30: cancel_plan com desfecho 15 → cancel_plan_conflicts_with_completed; nada muda" do
    done!(draft!(start, dental: { "plan_changes" => { "add" => [ restoration(21) ] } }))
    consultation = draft!(start, dental: { "dental_consultation_type" => 2, "dental_outcomes" => [ 15 ],
                                           "plan_changes" => { "cancel_plan" => { "reason" => "Paciente mudou de município" } } })
    expect(problems(finalize(consultation))).to eq([ [ "cancel_plan_conflicts_with_completed", "dental.plan_changes.cancel_plan" ] ])
    expect(plan_of(unit).reload.status).to eq("open")
  end

  it "O32: mais de 20 SIGTAP distintos → too_many_procedure_codes" do
    codes = DentalHelpers::SIGTAP.keys.select { |code| DentalCare::ProcedureSearch.searchable?(code) }.first(21)
    places = { "tooth" => { "tooth" => 11 }, "sextant" => { "sextant" => "S1" }, "arch" => { "arch" => "upper" }, "mouth" => {} }
    procedures = codes.map do |code|
      kind = DentalCare::ProcedureLimits.locations(code).first
      { "sigtap" => code, "location" => { "kind" => kind }.merge(places.fetch(kind)) }
    end
    consultation = draft!(start, dental: { "procedures" => procedures })
    expect(problems(finalize(consultation))).to eq([ [ "too_many_procedure_codes", "dental.procedures" ] ])
    draft!(consultation, dental: { "procedures" => procedures.first(20) })
    expect(finalize(consultation)).to be_ok
  end

  it "cancel_plan sem plano aberto na unidade → plan_item_not_open no cancel_plan" do
    consultation = draft!(start, dental: { "dental_consultation_type" => 2,
                                           "plan_changes" => { "cancel_plan" => { "reason" => "Paciente mudou de município" } } })
    expect(problems(finalize(consultation))).to eq([ [ "plan_item_not_open", "dental.plan_changes.cancel_plan" ] ])
  end

  it "achado de arcada: no rascunho sai { arch }; finalizado, um achado por dente permanente da arcada" do
    consultation = draft!(start, dental: { "findings" => [ { "arch" => "upper", "situation" => "complete_denture" } ] })
    expect(Consultations::Json.consultation(consultation)[:dental][:findings])
      .to eq([ { tooth: nil, face: nil, part: nil, arch: "upper", situation: "complete_denture" } ])
    done!(consultation)
    findings = Consultations::Json.consultation(consultation)[:dental][:findings]
    expect(findings.map { |f| f[:tooth] }).to match_array([ *11..18, *21..28 ].map(&:to_s))
    expect(findings.map { |f| f.values_at(:part, :arch, :situation) }.uniq).to eq([ [ "crown", nil, "complete_denture" ] ])
  end

  describe "registro inicial (Desvio 2)" do
    it "só achados: finaliza, eventos gravados, nenhum plano, care_type nulo" do
      consultation = draft!(start(baseline: true), { "dental" => { "findings" => [ { "tooth" => 16, "situation" => "caries" },
                                                                                   { "tooth" => 36, "situation" => "extracted" } ] } })
      done!(consultation)
      expect(consultation).to have_attributes(status: "finalized", care_type: nil, baseline: true)
      expect(consultation.dental_chart_events.pluck(:tooth, :situation)).to match_array([ [ 16, "caries" ], [ 36, "extracted" ] ])
      expect(DentalTreatmentPlan.count).to eq(0)
      expect(Ledi::ConsultationFicha.generate(consultation)).to eq(:skipped)
      expect(DomainEvent.where(name: "dental_consultation.finalized").sole.payload)
        .to eq("consultation_id" => consultation.id, "attendance_id" => consultation.attendance_id)
    end

    it "com procedimento → baseline_only_findings no procedures; sem achado → baseline_requires_findings" do
      consultation = draft!(start(baseline: true), { "dental" => { "findings" => [ { "tooth" => 16, "situation" => "caries" } ],
                                                                   "procedures" => [ restoration(16) ] } })
      expect(problems(finalize(consultation))).to eq([ [ "baseline_only_findings", "dental.procedures" ] ])
      empty = start(baseline: true, who: verified_citizen!(2))
      expect(problems(finalize(empty))).to eq([ [ "baseline_requires_findings", "dental.findings" ] ])
    end
  end

  it "periograma, registro periodontal e endodontia gravados; a endodontia concluída fecha o tratamento do dente; só o registro inicial pula a FAO" do
    perio = { "teeth" => [ { "tooth" => 16, "mobility" => 1, "furcation" => 2,
                             "sites" => [ { "site" => "MV", "probing_depth_mm" => 5, "recession_mm" => -1, "bleeding" => true },
                                          { "site" => "V", "probing_depth_mm" => 3, "recession_mm" => 0, "bleeding" => false } ] } ] }
    screening = { "sextants" => [ { "sextant" => "S1", "code" => 3, "star" => true }, { "sextant" => "S2", "code" => nil, "star" => false } ] }
    first = done!(draft!(start, dental: { "periodontal_chart" => perio, "periodontal_screening" => screening,
                                          "endodontics" => [ { "tooth" => 21, "canals" => 1, "status" => "in_progress" } ] }))
    chart = PeriodontalChart.find_by!(consultation_id: first.id)
    expect(chart).to have_attributes(tooth: 16, mobility: 1, furcation: 2)
    expect(chart.sites.pluck(:site, :probing_depth_mm, :recession_mm, :bleeding)).to match_array([ [ "MV", 5, -1, true ], [ "V", 3, 0, false ] ])
    expect(PeriodontalScreening.where(consultation_id: first.id).pluck(:sextant, :code, :star)).to match_array([ [ "S1", 3, true ], [ "S2", nil, false ] ])
    treatment = EndodonticTreatment.sole
    expect(treatment).to have_attributes(tooth: 21, status: "in_progress", health_unit_id: unit.id, opened_in_consultation_id: first.id)

    second = done!(draft!(start, dental: { "dental_consultation_type" => 2,
                                           "endodontics" => [ { "tooth" => 21, "canals" => 1, "status" => "completed" } ] }))
    expect(treatment.reload).to have_attributes(status: "completed", completed_in_consultation_id: second.id)
    expect(treatment.sessions.pluck(:consultation_id)).to match_array([ first.id, second.id ])
    # Task 9 (Ruling 17): a consulta odontológica gera a FAO; aqui a exportação está desligada.
    expect(Ledi::ConsultationFicha.generate(second)).to eq(:unusable)

    json = Consultations::Json.consultation(second)[:dental]
    expect(json).to include(care_type: "2", dental_consultation_type: "2", dental_outcomes: [ "16" ], oral_health_surveillance: [ "99" ])
    expect(json[:endodontics]).to eq([ { tooth: "21", canals: 1, status: "completed" } ])
    expect(Consultations::Json.consultation(first.reload)[:dental][:periodontal_chart][:teeth].sole).to include(tooth: "16", mobility: 1)
    names = DomainEvent.where("name LIKE 'dental%'").pluck(:name, :payload)
    expect(names.map(&:last)).to all(satisfy { |payload| (payload.keys - %w[consultation_id attendance_id plan_id]).empty? })
  end

  describe "GET /attendance/consultations/:id", type: :request do
    it "o rascunho odontológico traz o bloco dental com códigos string e suggest_completed; o care_type do topo espelha" do
      consultation = draft!(start, dental: { "care_type" => 6, "dental_consultation_type" => 1 })
      sign_in_as(dentist)
      get "/attendance/consultations/#{consultation.id}"
      body = JSON.parse(response.body)
      expect(body["care_type"]).to eq("6")
      expect(body["dental"]).to include("care_type" => "6", "dental_consultation_type" => "1", "suggest_completed" => false,
                                        "oral_health_surveillance" => [ "99" ])
      procedure = body["dental"]["procedures"].sole
      expect(procedure).to include("sigtap" => "0307010031", "name" => DentalHelpers::SIGTAP["0307010031"], "quantity" => 1,
                                   "location" => { "kind" => "face", "tooth" => "11", "face" => "M", "sextant" => nil, "arch" => nil })
    end

    it "PATCH com o bloco dental inválido → 422 com o path; finalize com problems" do
      consultation = start
      sign_in_as(dentist)
      json_patch "/attendance/consultations/#{consultation.id}", { "dental" => { "care_type" => 1 } }
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 422, { "error" => "invalid_care_type", "path" => "dental.care_type" } ])
      json_patch "/attendance/consultations/#{consultation.id}", dental_body(dental: { "oral_health_surveillance" => [] })
      expect(response).to have_http_status(:ok)
      json_post "/attendance/consultations/#{consultation.id}/finalize", { "outcome" => { "outcome" => "discharged" } }
      expect([ response.status, JSON.parse(response.body) ])
        .to eq([ 422, { "error" => "oral_health_surveillance_required", "path" => "dental.oral_health_surveillance",
                        "problems" => [ { "path" => "dental.oral_health_surveillance", "error" => "oral_health_surveillance_required" } ] } ])
    end
  end
end
