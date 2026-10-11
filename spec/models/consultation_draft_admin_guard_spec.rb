require "rails_helper"

# Rascunho órfão (card rotasaude/api#51; módulo 19a, ADR 0031): o admin
# municipal descarta (marca `discarded`, conteúdo clínico zerado, a linha fica
# como casca) ou designa outro profissional (troca a autora da consulta e quem
# chamou o atendimento). As duas escritas só passam no trigger sob a marca
# rota.draft_admin (Consultation.with_draft_admin); fora dela nada muda. A
# trilha consultation_draft_actions é só acréscimo, com motivo cifrado.
RSpec.describe "Guardas do rascunho órfão (rota.draft_admin)" do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  # let!: criado dentro de um savepoint recusado, o rollback o levaria.
  let!(:other_doctor) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:citizen) { verified_citizen!(1) }
  let(:patient) { Patient.create!(cpf: citizen.cpf) }
  let!(:attendance) { consulting_attendance!(unit, citizen: citizen, doctor: doctor) }
  let(:link) { doctor.professional.links.active.sole }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)
  def marker = ApplicationRecord.connection.select_value("SELECT current_setting('rota.draft_admin', true)")
  def as_draft_admin(&) = attempt { Consultation.with_draft_admin(&) }

  def consultation!(**over)
    Consultation.create!({ attendance: attendance, patient: patient, author_user: doctor, professional_link: link,
                           cbo_code: link.cbo_code, status: "draft", started_at: Time.current,
                           subjective: "MARCADOR-S", assessment: "avaliação", systolic: 120, diastolic: 80,
                           draft_items: { "conducts" => [ 1 ] } }.merge(over))
  end

  def discard_attributes = Consultation::CLINICAL_COLUMNS.index_with(nil).merge(status: "discarded", discarded_at: Time.current, draft_items: {})

  describe "consultations" do
    it "DELETE do rascunho continua recusado, com ou sem a marca" do
      consultation = consultation!
      expect { attempt { consultation.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { as_draft_admin { consultation.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "author_user_id muda só no rascunho e só sob a marca; as outras colunas de identidade nunca" do
      consultation = consultation!
      expect { attempt { consultation.update_columns(author_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      other_link = other_doctor.professional.links.active.sole
      as_draft_admin do
        consultation.update_columns(author_user_id: other_doctor.id, professional_link_id: other_link.id, cbo_code: other_link.cbo_code)
      end
      expect(consultation.reload.author_user_id).to eq(other_doctor.id)
      expect(consultation.subjective).to eq("MARCADOR-S")
      expect(consultation.draft_items).to eq("conducts" => [ 1 ])
      expect { as_draft_admin { consultation.update_columns(patient_id: Patient.create!(cpf: verified_citizen!(2).cpf).id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      expect { as_draft_admin { consultation.update_columns(created_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    end

    it "na finalizada, author_user_id não muda nem com a marca" do
      consultation = consultation!(draft_items: {})
      consultation.update!(status: "finalized", finalized_at: Time.current, care_type: 5)
      expect { as_draft_admin { consultation.update_columns(author_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    end

    it "draft → discarded só com a marca e com o conteúdo clínico zerado" do
      consultation = consultation!
      expect { attempt { consultation.update_columns(discard_attributes) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarding a draft needs rota.draft_admin/)
      expect { as_draft_admin { consultation.update_columns(discard_attributes.merge(plan: "sobrou texto")) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_discarded_empty/)
      expect { as_draft_admin { consultation.update_columns(discard_attributes.merge(heart_rate: 80)) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_discarded_empty/)
      expect { as_draft_admin { consultation.update_columns(discard_attributes.merge(discarded_at: nil)) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_discard/)
      expect { as_draft_admin { consultation.update_columns(discard_attributes.merge(draft_items: { "conducts" => [ 1 ] })) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_draft_items/)

      as_draft_admin { consultation.update_columns(discard_attributes) }
      consultation.reload
      expect(consultation).to be_discarded
      expect(consultation).not_to be_draft
      expect(consultation).not_to be_finalized
      expect(consultation.discarded_at).to be_present
      expect(consultation.vitals).to eq({})
      expect(Consultation::TEXT_FIELDS.map { |field| consultation[field] }).to all(be_nil)
      expect(consultation.author_user_id).to eq(doctor.id)
      expect(Consultation.finalized_consultations).not_to include(consultation)
    end

    it "descarta mesmo sem tipo de atendimento (care_type não é conteúdo clínico)" do
      consultation = consultation!(care_type: nil)
      expect { as_draft_admin { consultation.update_columns(discard_attributes) } }.not_to raise_error
    end

    it "discarded_at só com status discarded" do
      expect { attempt { consultation!(discarded_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_discard/)
    end

    it "descartada nunca muda (nem com a marca, nem de volta a rascunho)" do
      consultation = consultation!
      as_draft_admin { consultation.update_columns(discard_attributes) }
      expect { attempt { consultation.update_columns(care_type: 6) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarded consultation never changes/)
      expect { as_draft_admin { consultation.update_columns(care_type: 6) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarded consultation never changes/)
      expect { as_draft_admin { consultation.update_columns(status: "draft", discarded_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarded consultation never changes/)
      expect { as_draft_admin { consultation.update_columns(author_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change|discarded consultation never changes/)
      expect { attempt { consultation.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "status fora da lista recusado pelo CHECK" do
      expect { attempt { consultation!(status: "abandoned", care_type: 5, draft_items: {}) } }.to raise_error(ActiveRecord::StatementInvalid, /ck_consultations_status/)
    end
  end

  describe "Consultation.with_draft_admin" do
    it "liga a marca só dentro do bloco e devolve o valor do bloco" do
      consultation!
      value = attempt do
        result = Consultation.with_draft_admin { marker }
        expect(marker).to eq("off")
        result
      end
      expect(value).to eq("on")
    end

    it "a marca não sobra depois de uma falha no bloco (mesma transação externa)" do
      consultation = consultation!
      attempt do
        expect { Consultation.with_draft_admin { raise ArgumentError, "falhou no meio" } }.to raise_error(ArgumentError)
        expect(marker).not_to eq("on")
        expect { attempt { consultation.update_columns(author_user_id: other_doctor.id) } }
          .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      end
    end
  end

  describe "attendances (quem chamou)" do
    it "called_by_user_id do atendimento in_care muda só sob a marca, com called_at igual" do
      expect { attempt { attendance.update_columns(called_by_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the call never changes/)
      expect { as_draft_admin { attendance.update_columns(called_by_user_id: other_doctor.id, called_at: 1.minute.from_now) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the call never changes/)
      expect { as_draft_admin { attendance.update_columns(called_by_user_id: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the call never changes|ck_attendances_calling/)
      called_at = attendance.reload.called_at
      as_draft_admin { attendance.update_columns(called_by_user_id: other_doctor.id) }
      expect(attendance.reload.called_by_user_id).to eq(other_doctor.id)
      expect(attendance.called_at).to eq(called_at)
      expect(attendance.status).to eq("in_care")
    end

    it "sob a marca, não troca quem chamou ao encerrar nem no atendimento encerrado" do
      expect do
        as_draft_admin do
          attendance.update_columns(called_by_user_id: other_doctor.id, status: "closed", outcome: "discharged",
                                    closed_by_user_id: doctor.id, closed_at: Time.current)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /the call never changes/)
      # reload: o update_columns recusado acima deixa os valores atribuídos em memória.
      attendance.reload.update!(status: "closed", outcome: "discharged", closed_by_user: doctor, closed_at: Time.current)
      expect { as_draft_admin { attendance.update_columns(called_by_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /already closed/)
    end

    it "atendimento waiting não tem chamada a trocar: quem chamou sozinho cai no CHECK" do
      waiting = walk_in_attendance!(unit, citizen: verified_citizen!(3))
      expect { as_draft_admin { waiting.update_columns(called_by_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_attendances_calling/)
    end
  end

  # Regressão: numa sessão que NUNCA viu a marca, current_setting(..., true) é
  # NULL (não ''), e um NULL dentro de NOT (...) desligava a recusa em silêncio
  # (achado pela spec de invariantes do atendimento). A conexão do teste já viu
  # a marca; esta abre uma conexão nova e aplica as funções de trigger a cópias
  # temporárias das tabelas (sem FKs nem CHECKs), dentro de uma transação
  # desfeita no fim.
  describe "sessão que nunca viu a marca" do
    def fresh_connection
      info = ApplicationRecord.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password).compact
      PG.connect(**info)
    end

    def refused(pg, sql)
      pg.exec("SAVEPOINT s")
      pg.exec(sql)
      pg.exec("RELEASE SAVEPOINT s")
      nil
    rescue PG::RaiseException => e
      pg.exec("ROLLBACK TO SAVEPOINT s")
      e.message
    end

    it "sem a marca, trocar autora, descartar e trocar quem chamou continuam recusados" do
      pg = fresh_connection
      expect(pg.exec("SELECT current_setting('rota.draft_admin', true) AS v").getvalue(0, 0)).to be_nil
      pg.exec("BEGIN")
      pg.exec("CREATE TEMP TABLE t_att (LIKE attendances INCLUDING DEFAULTS)")
      pg.exec("CREATE TRIGGER g BEFORE UPDATE ON t_att FOR EACH ROW EXECUTE FUNCTION rota_attendance_guard()")
      pg.exec("INSERT INTO t_att (id, citizen_id, health_unit_id, checked_in_by_user_id, checked_in_at, check_in_method, created_at,
                                  status, called_at, called_by_user_id)
               VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), now(), 'code', now(),
                       'in_care', now(), gen_random_uuid())")
      expect(refused(pg, "UPDATE t_att SET called_by_user_id = gen_random_uuid()")).to match(/the call never changes/)

      pg.exec("CREATE TEMP TABLE t_con (LIKE consultations INCLUDING DEFAULTS)")
      pg.exec("CREATE TRIGGER g BEFORE UPDATE ON t_con FOR EACH ROW EXECUTE FUNCTION rota_consultation_guard()")
      pg.exec("INSERT INTO t_con (attendance_id, patient_id, author_user_id, professional_link_id, cbo_code, started_at, created_at, updated_at)
               VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '225125', now(), now(), now())")
      expect(refused(pg, "UPDATE t_con SET author_user_id = gen_random_uuid()")).to match(/identity columns never change/)
      expect(refused(pg, "UPDATE t_con SET status = 'discarded', discarded_at = now()")).to match(/discarding a draft needs rota.draft_admin/)
    ensure
      pg&.exec("ROLLBACK") rescue nil
      pg&.close
    end
  end

  describe "consultation_draft_actions" do
    def action!(consultation, **over)
      ConsultationDraftAction.create!({ consultation: consultation, attendance: attendance, action: "discarded", by_user: admin,
                                        previous_author_user: doctor, reason: "MARCADOR-MOTIVO profissional desligado" }.merge(over))
    end

    it "só acréscimo; motivo cifrado; a re-cifra só regrava o motivo" do
      consultation = consultation!
      row = action!(consultation)
      expect(row.reload.reason).to eq("MARCADOR-MOTIVO profissional desligado")
      raw = ApplicationRecord.connection.select_value("SELECT reason FROM consultation_draft_actions WHERE id = #{ApplicationRecord.connection.quote(row.id)}")
      expect(raw).not_to include("MARCADOR")
      expect(row.inspect).not_to include("MARCADOR")
      expect { attempt { row.update_columns(action: "reassigned", new_author_user_id: other_doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { row.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only: DELETE refused/)
      expect { attempt { ApplicationRecord.connection.execute("TRUNCATE consultation_draft_actions") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: TRUNCATE refused/)
      expect { CityEncryption.allowing_reencryption { row.encrypt } }.not_to raise_error
      expect(row.reload.reason).to eq("MARCADOR-MOTIVO profissional desligado")
      expect { attempt { CityEncryption.allowing_reencryption { row.update_columns(by_user_id: doctor.id) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
      expect { attempt { Consultation.with_draft_admin { row.update_columns(by_user_id: doctor.id) } } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only: UPDATE refused/)
    end

    it "CHECKs: ação da lista; novo autor só (e sempre) na designação" do
      consultation = consultation!
      expect { action!(consultation, action: "reassigned", new_author_user: other_doctor) }.not_to raise_error
      { { action: "deleted" } => /ck_consultation_draft_actions_action/,
        { action: "reassigned" } => /ck_consultation_draft_actions_new_author/,
        { action: "discarded", new_author_user: other_doctor } => /ck_consultation_draft_actions_new_author/ }.each do |attrs, error|
        expect { attempt { action!(consultation, **attrs) } }.to raise_error(ActiveRecord::StatementInvalid, error), attrs.inspect
      end
      expect { attempt { action!(consultation, reason: nil) } }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end
