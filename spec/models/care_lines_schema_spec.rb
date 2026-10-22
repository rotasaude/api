require "rails_helper"

# ADR 0040 (spec §4): só acréscimo onde a spec manda; cifra; unicidades.
RSpec.describe "Linhas de cuidado — banco da cidade" do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:team) { care_team!(unit, doctor) }
  let(:line) { adopted_line!("diabetes_c4") }
  let(:patient) { care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ]) }

  def sql(statement) = ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }

  it "uma inscrição ativa por paciente e linha; encerrada libera" do
    enrollment = care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    expect { care_enrollment!(patient: patient, line: line, team: team, by: doctor) }.to raise_error(ActiveRecord::RecordNotUnique)
    enrollment.update!(status: "ended", ended_reason: "discharge", ended_at: Time.current, ended_by_user: doctor)
    expect(care_enrollment!(patient: patient, line: line, team: team, by: doctor)).to be_persisted
  end

  it "inscrição: só a saída muda, uma vez; nada se apaga" do
    enrollment = care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    other_team = care_team!(unit)
    expect { sql("UPDATE care_line_enrollments SET team_id = '#{other_team.id}' WHERE id = '#{enrollment.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /only the ending columns change/)
    enrollment.update!(status: "ended", ended_reason: "moved", ended_at: Time.current, ended_by_user: doctor)
    expect { sql("UPDATE care_line_enrollments SET ended_reason = 'death' WHERE id = '#{enrollment.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /an ended enrollment is frozen/)
    expect { sql("DELETE FROM care_line_enrollments WHERE id = '#{enrollment.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /rows are never deleted/)
  end

  it "contato só acréscimo e nota cifrada" do
    enrollment = care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    contact = CareOutreachContact.create!(enrollment: enrollment, channel: "phone", outcome: "no_answer", note: "Não atendeu às 10h",
                                          recorded_by_user: doctor, recorded_at: Time.current)
    raw = ApplicationRecord.connection.select_value("SELECT note FROM care_outreach_contacts WHERE id = '#{contact.id}'")
    expect(raw).not_to include("atendeu")
    expect { sql("UPDATE care_outreach_contacts SET outcome = 'reached' WHERE id = '#{contact.id}'") }.to raise_error(ActiveRecord::StatementInvalid)
    expect { sql("DELETE FROM care_outreach_contacts WHERE id = '#{contact.id}'") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "condição declarada: cifrada, retirar uma vez, DELETE passa (exclusão LGPD)" do
    citizen = verified_citizen!(exam_seq!)
    condition = CitizenDeclaredCondition.create!(citizen: citizen, condition: "diabetes", declared_at: Time.current)
    raw = ApplicationRecord.connection.select_value("SELECT condition FROM citizen_declared_conditions WHERE id = '#{condition.id}'")
    expect(raw).not_to include("diabetes")
    condition.update!(withdrawn_at: Time.current)
    expect { sql("UPDATE citizen_declared_conditions SET withdrawn_at = NULL WHERE id = '#{condition.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /citizen_declared_conditions/)
    expect { sql("DELETE FROM citizen_declared_conditions WHERE id = '#{condition.id}'") }.not_to raise_error
  end

  it "sugestão: pessoa é paciente OU par; uma pendente por pessoa e linha; decidida congela; DELETE passa" do
    citizen = verified_citizen!(exam_seq!)
    expect { CareLineSuggestion.create!(care_line: line, team: team, reason: "age_sex") }.to raise_error(ActiveRecord::StatementInvalid)
    one = CareLineSuggestion.create!(care_line: line, team: team, citizen: citizen, reason: "declared")
    expect { CareLineSuggestion.create!(care_line: line, team: team, citizen: citizen, reason: "declared") }
      .to raise_error(ActiveRecord::RecordNotUnique)
    one.update!(status: "dismissed", decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Já acompanhada no CAPS")
    expect { sql("UPDATE care_line_suggestions SET decided_at = decided_at + interval '1 day' WHERE id = '#{one.id}'") }
      .to raise_error(ActiveRecord::StatementInvalid, /a decided suggestion is frozen/)
    expect { sql("DELETE FROM care_line_suggestions WHERE id = '#{one.id}'") }.not_to raise_error
  end

  # Revisão da Task 5: a sugestão de encerramento (resolved_problem) é de outro
  # assunto que a de inscrição da mesma pessoa e linha, e é uma por inscrição.
  it "sugestão de encerramento pendente convive com a de inscrição pendente da mesma pessoa e linha" do
    enrollment = care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    enroll_one = CareLineSuggestion.create!(patient: patient, care_line: line, team: team, reason: "problem")
    closure = CareLineSuggestion.create!(patient: patient, care_line: line, team: team, reason: "resolved_problem", enrollment: enrollment)
    expect([ enroll_one, closure ]).to all(be_persisted)
    expect { CareLineSuggestion.create!(patient: patient, care_line: line, team: team, reason: "problem") }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_care_line_suggestions_one_patient/)
  end

  it "não há duas sugestões de encerramento pendentes para a mesma inscrição" do
    enrollment = care_enrollment!(patient: patient, line: line, team: team, by: doctor)
    CareLineSuggestion.create!(patient: patient, care_line: line, team: team, reason: "resolved_problem", enrollment: enrollment)
    expect { CareLineSuggestion.create!(patient: patient, care_line: line, team: team, reason: "resolved_problem", enrollment: enrollment) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_care_line_suggestions_one_closure/)
  end

  # CityRekey e ReencryptionJob regravam o texto cifrado de toda linha de
  # CITY_KEYED_TARGETS sob a marca rota.reencrypting; os guardas da inscrição,
  # da sugestão, do contato e da condição precisam deixar passar só isso.
  it "re-cifra regrava só o texto cifrado, e só sob a marca" do
    enrollment = care_enrollment!(patient: patient, line: line, team: team, by: doctor, anchor_date: Time.zone.today - 40)
    contact = CareOutreachContact.create!(enrollment: enrollment, channel: "phone", outcome: "no_answer", note: "Sem sinal",
                                          recorded_by_user: doctor, recorded_at: Time.current)
    citizen = verified_citizen!(exam_seq!)
    condition = CitizenDeclaredCondition.create!(citizen: citizen, condition: "diabetes", declared_at: Time.current)
    condition.update!(withdrawn_at: Time.current)
    suggestion = CareLineSuggestion.create!(care_line: line, team: team, citizen: citizen, reason: "declared")
    suggestion.update!(status: "dismissed", decided_by_user: doctor, decided_at: Time.current, dismiss_reason: "Já acompanhada")
    enrollment.update!(status: "ended", ended_reason: "other", ended_note: "Mudou de cidade", ended_at: Time.current, ended_by_user: doctor)

    # nenhum dado pessoal em inspect (DUM, notas, motivo, condição)
    expect([ enrollment.reload, contact, condition, suggestion ].map(&:inspect).join).not_to match(/Sem sinal|diabetes|Mudou|acompanhada/)

    [ enrollment.reload, contact, condition, suggestion ].each do |record|
      expect { ApplicationRecord.transaction(requires_new: true) { record.encrypt } }
        .to raise_error(ActiveRecord::StatementInvalid, /#{record.class.table_name}/)
      expect { CityEncryption.allowing_reencryption { record.encrypt } }.not_to raise_error
    end
    # Terceira direção: sob a marca, coluna NÃO cifrada continua recusada (a
    # exceção é só do texto cifrado). Mensagem do guard de cada tabela.
    other_team = care_team!(unit)
    later = Time.current + 1.day
    {
      "only the ending columns change" => [ enrollment, { team_id: other_team.id } ],
      "an ended enrollment is frozen" => [ enrollment, { ended_reason: "death" } ],
      "append-only" => [ contact, { outcome: "reached" } ],
      "only withdrawn_at, once" => [ condition, { withdrawn_at: later } ],
      "only the decision columns change" => [ suggestion, { team_id: other_team.id } ],
      "a decided suggestion is frozen" => [ suggestion, { decided_at: later } ]
    }.each do |message, (record, columns)|
      expect { ApplicationRecord.transaction(requires_new: true) { CityEncryption.allowing_reencryption { record.update_columns(columns) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /#{message}/)
    end

    expect(enrollment.reload.anchor_date).to eq((Time.zone.today - 40).iso8601)
    expect(enrollment.ended_note).to eq("Mudou de cidade")
    expect(contact.reload.note).to eq("Sem sinal")
    expect(condition.reload.condition).to eq("diabetes")
    expect(suggestion.reload.dismiss_reason).to eq("Já acompanhada")
  end

  it "linha: uma adoção por template e uma linha ativa por condição declarada" do
    line
    expect { CareLine.create!(source: "template", template_key: "diabetes_c4", template_version: 1, indicator: "C4", name: "Outra",
                              eligibility: line.eligibility, practices: line.practices, updated_by_user: doctor) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect { CareLine.create!(source: "custom", name: "Diabetes 2", eligibility: line.eligibility, practices: line.practices,
                              declared_condition: "diabetes", updated_by_user: doctor) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
