require "rails_helper"

# Módulo 32a (ADR 0050; plano, Desvio 2): o atendimento do 13 ganha a origem
# `walk_in` — a chegada na UPA, sem triagem, sem horário e sem o par do wpda:
# a pessoa é o Patient. As recusas vêm do banco (CHECKs, índices e os
# triggers de db/city_triggers.sql), não só do modelo.
RSpec.describe "Atendimento do 13 com a origem walk_in", type: :model do
  let!(:city) { clinical_city! }
  let!(:upa) { create_unit("UPA Teste", kind: "upa") }
  let!(:ubs) { create_unit("UBS Teste") }
  let(:patient) { Patient.create!(cpf: "52998224725", full_name: "Rosa Maria Campos", birth_date: "1970-05-05", sex: "female") }

  def walk_in!(unit, **over)
    Attendance.create!({ origin_kind: "walk_in", patient: patient, health_unit: unit, checked_in_by_user: reception!,
                         checked_in_at: Time.current, check_in_method: "urgency_reception" }.merge(over))
  end

  # Savepoint: cada recusa aborta a transação; o savepoint deixa a próxima viva.
  def attempt(&block) = ApplicationRecord.transaction(requires_new: true, &block)

  it "walk_in só na UPA, sem cidadão e sem triagem; o par do 13 continua obrigatório fora dele" do
    expect(walk_in!(upa).citizen_id).to be_nil
    expect { attempt { walk_in!(ubs) } }.to raise_error(ActiveRecord::StatementInvalid, /walk_in only at an upa/)
    expect { attempt { walk_in!(upa, citizen: screening_citizen!(1)) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_origin/)
    expect { attempt { walk_in!(upa, check_in_method: "code") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_walk_in_method/)
    expect { attempt { Attendance.insert_all!([ { health_unit_id: ubs.id, checked_in_by_user_id: reception!.id, checked_in_at: Time.current,
                                                  check_in_method: "code", status: "waiting", created_at: Time.current } ]) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_origin/)
  end

  it "um walk_in aberto por paciente e UPA; o paciente, a senha e a origem nunca mudam" do
    a = walk_in!(upa)
    expect { attempt { walk_in!(upa) } }.to raise_error(ActiveRecord::RecordNotUnique, /idx_attendances_open_walk_in/)
    expect { attempt { a.update_column(:origin_kind, "triage") } }.to raise_error(ActiveRecord::StatementInvalid, /check-in columns never change/)
    expect { attempt { a.update_column(:patient_id, Patient.create!(cpf: "11144477735", full_name: "Outra Pessoa", birth_date: "1990-01-01", sex: "male").id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /check-in columns never change/)
    b = walk_in!(create_unit("UPA Norte", kind: "upa"), ticket: "U-001", ticket_on: Date.current)
    expect { attempt { b.update_column(:ticket, "U-002") } }.to raise_error(ActiveRecord::StatementInvalid, /check-in columns never change/)
    expect { attempt { b.update_column(:ticket_on, Date.current + 1) } }.to raise_error(ActiveRecord::StatementInvalid, /check-in columns never change/)
  end

  it "a senha vem com o dia, no formato, única por unidade e dia" do
    expect { attempt { walk_in!(upa, ticket: "U-001") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_ticket/)
    expect { attempt { walk_in!(upa, ticket: "u-1", ticket_on: Date.current) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_ticket/)
    walk_in!(upa, ticket: "U-001", ticket_on: Date.current)
    other = Patient.create!(cpf: "11144477735", full_name: "Outra Pessoa", birth_date: "1990-01-01", sex: "male")
    expect { attempt { walk_in!(upa, patient: other, ticket: "U-001", ticket_on: Date.current) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_attendances_ticket/)
    expect(walk_in!(upa, patient: other, ticket: "U-001", ticket_on: Date.current - 1).ticket).to eq("U-001")
  end

  it "o check-in do 13 deduz a origem pelo par, no modelo e no banco; a pessoa é o cidadão ou o paciente" do
    citizen = screening_citizen!(2)
    a = walk_in_attendance!(ubs, citizen: citizen)
    expect(a.origin_kind).to eq("triage")
    expect(a).not_to be_walk_in
    expect(a.person).to eq(citizen)
    triage = completed_web_triage_for(citizen)
    Attendance.insert_all!([ { triage_id: triage.id, citizen_id: citizen.id, health_unit_id: upa.id, checked_in_by_user_id: reception!.id,
                               checked_in_at: Time.current, check_in_method: "code", status: "waiting", created_at: Time.current } ])
    expect(Attendance.find_by(triage_id: triage.id).origin_kind).to eq("triage")
    w = walk_in!(upa)
    expect(w).to be_walk_in
    expect(w.person).to eq(patient)
    expect(Attendance.new(origin_kind: "triage", health_unit: ubs)).not_to be_valid
  end
end
