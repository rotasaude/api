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
