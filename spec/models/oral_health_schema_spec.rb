require "rails_helper"

# Módulo 28 (ADR 0046): o banco da saúde bucal. A consulta odontológica é a
# mesma linha de consultations (kind = dental); os CHECKs e os triggers
# (db/city_triggers.sql) seguram o que o código não pode quebrar.
RSpec.describe "Esquema da saúde bucal (ADR 0046)" do
  before { dental_city! }

  let(:unit) { create_unit("UBS Sorriso #{SecureRandom.hex(2)}") }
  let(:dentist) { dentist!(unit) }
  # let!: criada fora de qualquer savepoint de recusa (o ROLLBACK TO
  # SAVEPOINT a apagaria e o objeto memorizado ficaria órfão).
  let!(:consultation) { dental_row!(unit: unit, by: dentist, citizen: verified_citizen!(1, full_name: "Ana Paula Ribeiro")) }

  # Escrita crua que o banco recusa: savepoint próprio, senão a recusa aborta a
  # transação do exemplo (como no esquema da farmácia).
  def refused(error = ActiveRecord::StatementInvalid, pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(error, pattern)
  end

  # Consulta odontológica em rascunho gravada direto (o Start com `kind` é da
  # Task 4): atendimento in_care chamado pela dentista, paciente resolvido.
  def dental_row!(unit:, by:, citizen:, baseline: false, kind: "dental")
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: by)
    patient = Patients::Resolve.call(citizen).payload.fetch(:patient)
    Consultation.create!(attendance: attendance, patient: patient, author_user: by, professional_link: by.professional.links.active.first,
                         cbo_code: "223208", status: "draft", kind: kind, baseline: baseline, started_at: Time.current)
  end

  # Linha recarregada: as tentativas recusadas deixam itens não salvos no
  # alvo das associações em memória, e o save do pai os regravaria.
  def finalize!(row)
    Consultation.find(row.id).update!(status: "finalized", finalized_at: Time.current, care_type: 2)
    row.reload
  end

  def chart_event(row, **over)
    DentalChartEvent.create!({ patient: row.patient, consultation: row, tooth: 11, part: "crown", situation: "caries",
                               author_user: dentist, cbo_code: "223208", recorded_at: Time.current }.merge(over))
  end

  def plan!(row, health_unit: unit)
    DentalTreatmentPlan.create!(patient: row.patient, health_unit: health_unit, status: "open", opened_in_consultation: row)
  end

  it "consulta geral não leva campo odontológico; tipo de atendimento por tipo de consulta" do
    general = started_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(2, full_name: "Rita Souza"))
    expect(general.kind).to eq("general")
    refused(ActiveRecord::StatementInvalid, /ck_consultations_dental_fields/) { general.update_columns(pregnant: true) }
    refused(ActiveRecord::StatementInvalid, /ck_consultations_care_type/) { general.update_columns(care_type: 4) }

    refused(ActiveRecord::StatementInvalid, /ck_consultations_care_type/) { consultation.update_columns(care_type: 1) }
    consultation.update!(care_type: 4, dental_consultation_type: 1, oral_health_surveillance: [ 99 ], dental_outcomes: [ 16 ], pregnant: false)
    expect(consultation.reload).to have_attributes(care_type: 4, oral_health_surveillance: [ 99 ], dental_outcomes: [ 16 ])
    refused(ActiveRecord::StatementInvalid, /ck_consultations_oral_health_surveillance/) { consultation.update_columns(oral_health_surveillance: [ 7 ]) }
    refused(ActiveRecord::StatementInvalid, /ck_consultations_dental_outcomes/) { consultation.update_columns(dental_outcomes: [ 13 ]) }
    refused(ActiveRecord::StatementInvalid, /ck_consultations_dental_consultation_type/) { consultation.update_columns(dental_consultation_type: 3) }
  end

  it "registro inicial só na odontológica, finalizado sem tipo de atendimento" do
    baseline = dental_row!(unit: unit, by: dentist, citizen: verified_citizen!(4, full_name: "Carla Dias"), baseline: true)
    baseline.update!(status: "finalized", finalized_at: Time.current, care_type: nil)
    expect(baseline.reload).to be_finalized
    refused(ActiveRecord::StatementInvalid, /ck_consultations_finalized_care_type/) do
      consultation.update_columns(status: "finalized", finalized_at: Time.current, care_type: nil)
    end
    general = dental_row!(unit: unit, by: dentist, citizen: verified_citizen!(3, full_name: "Lia Campos"), kind: "general")
    refused(ActiveRecord::StatementInvalid, /ck_consultations_baseline/) do
      Consultation.create!(general.attributes.slice("patient_id", "author_user_id", "professional_link_id", "cbo_code", "started_at")
                                  .merge("attendance_id" => walk_in_attendance!(unit, citizen: general.attendance.citizen).id,
                                         "status" => "draft", "kind" => "general", "baseline" => true))
    end
  end

  it "kind e baseline nunca mudam, nem no rascunho" do
    refused(ActiveRecord::StatementInvalid, /identity columns never change/) { consultation.update_columns(kind: "general") }
    refused(ActiveRecord::StatementInvalid, /identity columns never change/) { consultation.update_columns(baseline: true) }
    expect(consultation.reload.kind).to eq("dental")
  end

  it "evento do odontograma: no rascunho ou com adendo desta consulta; nunca muda nem some" do
    event = chart_event(consultation)
    refused(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/) { event.update_columns(situation: "restored") }
    refused(ActiveRecord::StatementInvalid, /append-only: DELETE refused/) { event.delete }
    refused(ActiveRecord::StatementInvalid, /append-only: TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE dental_chart_events") }
    refused(ActiveRecord::StatementInvalid, /ck_dental_chart_events_finding/) { chart_event(consultation, situation: nil) }
    refused(ActiveRecord::StatementInvalid, /ck_dental_chart_events_face/) { chart_event(consultation, part: "root", face: "M") }

    finalize!(consultation)
    refused(ActiveRecord::StatementInvalid, /only come with an addendum/) { chart_event(consultation) }
    addendum = ConsultationAddendum.create!(consultation: consultation, author_user: dentist, reason: "Corrige o achado do dente 11",
                                            text: "Achado corrigido", item_changes: {})
    expect(chart_event(consultation, addendum: addendum, situation: "restored")).to be_persisted
  end

  it "procedimento: local coerente; sem adendo, só no rascunho; nunca muda" do
    attrs = { consultation: consultation, patient: consultation.patient, procedure_code: "0307010031", location_kind: "face", tooth: 11,
              quantity: 1 }
    refused(ActiveRecord::StatementInvalid, /ck_dental_procedures_location/) { DentalProcedure.create!(attrs) }
    refused(ActiveRecord::StatementInvalid, /ck_dental_procedures_location/) { DentalProcedure.create!(attrs.merge(face: "M", sextant: "S1")) }
    refused(ActiveRecord::StatementInvalid, /ck_dental_procedures_tooth/) { DentalProcedure.create!(attrs.merge(face: "M", tooth: 19)) }
    procedure = DentalProcedure.create!(attrs.merge(face: "M"))
    expect(DentalProcedure.create!(attrs.merge(location_kind: "mouth", tooth: nil))).to be_persisted
    refused(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/) { procedure.update_columns(quantity: 2) }
    finalize!(consultation)
    refused(ActiveRecord::StatementInvalid, /only come with an addendum/) { DentalProcedure.create!(attrs.merge(face: "M")) }
  end

  it "um plano aberto por paciente e unidade; item feito nunca volta a planejado" do
    plan = plan!(consultation)
    refused(ActiveRecord::RecordNotUnique, /idx_dental_plans_one_open/) { plan!(consultation) }
    expect(plan!(consultation, health_unit: create_unit("CEO Centro #{SecureRandom.hex(2)}", kind: "ceo"))).to be_persisted

    item = DentalTreatmentPlanItem.create!(dental_treatment_plan: plan, procedure_code: "0307010031", location_kind: "tooth", tooth: 11,
                                           status: "planned", added_in_consultation: consultation)
    item.update!(status: "done", done_in_consultation: consultation)
    refused(ActiveRecord::StatementInvalid, /changed once, from planned/) { item.update_columns(status: "planned", done_in_consultation_id: nil) }
    refused(ActiveRecord::StatementInvalid, /DELETE refused/) { item.delete }

    refused(ActiveRecord::StatementInvalid, /ck_dental_treatment_plans_cancel_reason/) do
      plan.update_columns(status: "cancelled", closed_at: Time.current)
    end
    plan.reload
    plan.update!(status: "cancelled", closed_at: Time.current, closed_by_user: dentist, cancel_reason: "Paciente mudou de cidade")
    refused(ActiveRecord::StatementInvalid, /closed once, from open/) { plan.update_columns(status: "open", closed_at: nil, cancel_reason: nil) }
    expect(plan.inspect).not_to include("mudou")
  end

  it "prótese: etapas em ordem; instalada e cancelada nunca mudam; laboratório por um só caminho" do
    attrs = { patient: consultation.patient, health_unit: unit, consultation: consultation, procedure_code: "0701070129", stage: "impression",
              laboratory_name: "Laboratório Sorriso", created_by_user: dentist }
    refused(ActiveRecord::StatementInvalid, /ck_dental_prosthesis_orders_laboratory/) { DentalProsthesisOrder.create!(attrs.merge(laboratory_name: nil)) }
    refused(ActiveRecord::StatementInvalid, /ck_dental_prosthesis_orders_laboratory_name/) { DentalProsthesisOrder.create!(attrs.merge(laboratory_name: "AB")) }
    refused(ActiveRecord::StatementInvalid, /ck_dental_prosthesis_orders_procedure_code/) { DentalProsthesisOrder.create!(attrs.merge(procedure_code: "0701070110")) }

    order = DentalProsthesisOrder.create!(attrs)
    refused(ActiveRecord::StatementInvalid, /invalid stage transition/) { order.update_columns(stage: "received") }
    order.update!(stage: "sent")
    order.update!(stage: "received")
    order.update!(stage: "installed", installed_in_consultation: consultation)
    refused(ActiveRecord::StatementInvalid, /never changes/) { order.update_columns(stage: "sent", installed_in_consultation_id: nil) }
    refused(ActiveRecord::StatementInvalid, /DELETE refused/) { order.delete }

    refused(ActiveRecord::StatementInvalid, /ck_dental_prosthesis_stages_reason/) do
      DentalProsthesisStage.create!(dental_prosthesis_order: order, stage: "cancelled", by_user: dentist)
    end
    stage = DentalProsthesisStage.create!(dental_prosthesis_order: order, stage: "cancelled", by_user: dentist, reason: "Paciente desistiu da prótese")
    refused(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/) { stage.update_columns(stage: "sent") }
  end

  it "periodontal: sextante excluído sem código; faixas do periograma" do
    expect(PeriodontalScreening.create!(consultation: consultation, patient: consultation.patient, sextant: "S1", code: nil)).to be_persisted
    refused(ActiveRecord::RecordNotUnique) { PeriodontalScreening.create!(consultation: consultation, patient: consultation.patient, sextant: "S1", code: 2) }
    refused(ActiveRecord::StatementInvalid, /ck_periodontal_screenings_code/) do
      PeriodontalScreening.create!(consultation: consultation, patient: consultation.patient, sextant: "S2", code: 5)
    end
    chart = PeriodontalChart.create!(consultation: consultation, patient: consultation.patient, tooth: 16, mobility: 1, furcation: 0)
    expect(PeriodontalSite.create!(periodontal_chart: chart, site: "MV", probing_depth_mm: 4, recession_mm: -10, bleeding: true)).to be_persisted
    refused(ActiveRecord::StatementInvalid, /ck_periodontal_sites_recession/) do
      PeriodontalSite.create!(periodontal_chart: chart, site: "V", probing_depth_mm: 4, recession_mm: -11, bleeding: false)
    end
  end

  it "endodontia: uma em andamento por dente; concluída nunca muda" do
    attrs = { patient: consultation.patient, health_unit: unit, tooth: 36, canals: 3, status: "in_progress", opened_in_consultation: consultation }
    treatment = EndodonticTreatment.create!(attrs)
    refused(ActiveRecord::RecordNotUnique, /idx_endodontic_treatments_one_in_progress/) { EndodonticTreatment.create!(attrs) }
    treatment.update!(canals: 4)
    treatment.update!(status: "completed", completed_in_consultation: consultation)
    refused(ActiveRecord::StatementInvalid, /never changes/) { treatment.update_columns(canals: 2) }
  end

  it "equipes e unidades: eSB 71 com equipe associada; unidade CEO; perfil do CEO nunca some" do
    esf = HealthTeam.create!(health_unit: unit, ine: "0001234570", kind: "70", name: "eSF Jardim")
    esb = HealthTeam.create!(health_unit: unit, ine: "0001234571", kind: "71", name: "eSB Jardim", associated_team: esf)
    expect(esb.associated_team).to eq(esf)
    refused(ActiveRecord::StatementInvalid, /ck_health_teams_associated_team/) { esf.update_columns(associated_team_id: esb.id) }

    expect(HealthUnit.new(name: "CEO Centro", kind: "ceo")).to be_valid
    ceo = create_unit("CEO Norte #{SecureRandom.hex(2)}", kind: "ceo")
    profile = CeoProfile.create!(health_unit: ceo, ceo_type: "II", specialties: %w[endodontics prosthesis], updated_by_user: dentist)
    expect(ceo.reload.ceo_profile).to eq(profile)
    refused(ActiveRecord::StatementInvalid, /ck_ceo_profiles_specialties/) { profile.update_columns(specialties: %w[orthodontics]) }
    refused(ActiveRecord::StatementInvalid, /ck_ceo_profiles_specialties/) { profile.update_columns(specialties: []) }
    refused(ActiveRecord::StatementInvalid, /DELETE refused/) { profile.delete }
  end

  it "lista do TSB/ASB nasce com a semente; inspect sem dado clínico" do
    expect(DentalAuxiliaryProcedure.pluck(:procedure_code)).to match_array(DentalCare::Catalog::AUXILIARY_DEFAULT_PROCEDURES)

    event = chart_event(consultation, tooth: 47, situation: "extraction_indicated")
    [ event.inspect, event.to_s ].each do |text|
      expect(text).to include(event.id)
      # Sem o valor nem a chave: o id (hex) pode conter os dígitos do dente.
      expect(text).not_to include("extraction_indicated")
      expect(text).not_to match(/tooth|situation|part=/)
    end
  end
end
