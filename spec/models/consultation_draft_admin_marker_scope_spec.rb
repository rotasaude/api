require "rails_helper"

# Escopo da marca rota.draft_admin (card rotasaude/api#51; módulo 19a, ADR 0031).
# SET LOCAL dentro de um savepoint: se o savepoint é revertido a marca volta; se
# é liberado (RELEASE) ela PERSISTE até o fim da transação de topo — por isso o
# helper devolve a marca a 'off' no sucesso. Aqui: (1) a marca não vaza para
# outra transação da mesma conexão nem depois de sucesso, falha de comando ou
# exceção no bloco; (2) com a marca ligada, nada clínico finalizado muda.
# O gancho do arquivo anterior (consultation_draft_admin_guard_spec.rb) cobre o
# trigger em si; os casos já lá (autora de finalizada, descartada imutável,
# DELETE de rascunho, helper devolve valor/falha) não se repetem.
RSpec.describe "Marca rota.draft_admin: não vaza e não alcança o finalizado" do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let!(:colleague) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:reason) { "Profissional desligada da unidade, rascunho sem dono" }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)
  def marker = ApplicationRecord.connection.select_value("SELECT current_setting('rota.draft_admin', true)")

  # Rascunho com a autora ainda vinculada (alvo das tentativas de troca sem marca).
  def draft_of!(author, number)
    started_consultation!(unit: unit, doctor: author, citizen: verified_citizen!(number))
  end

  def orphan!(number, author = doctor)
    draft_of!(author, number).tap do
      ProfessionalLink.joins(:professional).where(professionals: { user_id: author.id })
                      .find_each { |link| link.update!(ended_at: Time.current, ended_by_user: admin) }
    end
  end

  def expect_swap_refused(consultation)
    expect { attempt { consultation.update_columns(author_user_id: SecureRandom.uuid) } }
      .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    expect(consultation.reload.author_user_id).to eq(colleague.id)
  end

  describe "não vaza para outra transação da mesma conexão" do
    it "depois de Discard com sucesso, a marca não vale (e a troca de autora de outro rascunho é recusada)" do
      target = draft_of!(colleague, 1)
      orphan = orphan!(2)

      expect(ConsultationDrafts::Discard.call(consultation_id: orphan.id, reason: reason, by: admin)).to be_ok
      expect(marker).not_to eq("on")
      expect_swap_refused(target)
      expect { attempt { target.update_columns(status: "discarded", discarded_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarding a draft needs rota.draft_admin/)
    end

    it "depois de Reassign com sucesso, a marca não vale" do
      target = draft_of!(colleague, 1)
      orphan = orphan!(2)
      third = doctor!(unit)

      expect(ConsultationDrafts::Reassign.call(consultation_id: orphan.id, user_id: third.id, reason: reason, by: admin)).to be_ok
      expect(marker).not_to eq("on")
      expect_swap_refused(target)
      # E quem chamou o atendimento (ligado à mesma marca) também não troca.
      expect { attempt { target.attendance.update_columns(called_by_user_id: doctor.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /the call never changes/)
    end

    it "depois de Discard que FALHA dentro do bloco (a trilha levanta), a marca não vale e o descarte não ficou" do
      target = draft_of!(colleague, 1)
      orphan = orphan!(2)
      allow(ConsultationDraftAction).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "falha da trilha")

      expect { ConsultationDrafts::Discard.call(consultation_id: orphan.id, reason: reason, by: admin) }
        .to raise_error(ActiveRecord::StatementInvalid, /falha da trilha/)
      expect(marker).not_to eq("on")
      expect(orphan.reload.status).to eq("draft")
      expect_swap_refused(target)
    end

    it "depois de Reassign que FALHA dentro do bloco, a marca não vale e nada trocou" do
      target = draft_of!(colleague, 1)
      orphan = orphan!(2)
      third = doctor!(unit)
      allow(ConsultationDraftAction).to receive(:create!).and_raise(ArgumentError, "falha da trilha")

      expect { ConsultationDrafts::Reassign.call(consultation_id: orphan.id, user_id: third.id, reason: reason, by: admin) }
        .to raise_error(ArgumentError)
      expect(marker).not_to eq("on")
      expect(orphan.reload.author_user_id).to eq(doctor.id)
      expect(orphan.attendance.reload.called_by_user_id).to eq(doctor.id)
      expect_swap_refused(target)
    end

    it "depois de erro de SQL dentro do bloco (transação abortada e revertida ao savepoint), a marca não vale" do
      target = draft_of!(colleague, 1)
      expect do
        Consultation.with_draft_admin { target.update_columns(status: "bogus") } # recusado pelo CHECK
      end.to raise_error(ActiveRecord::StatementInvalid)
      expect(marker).not_to eq("on")
      expect_swap_refused(target)
    end

    it "um bloco que termina com sucesso dentro de um rescue do chamador também desliga a marca" do
      target = draft_of!(colleague, 1)
      begin
        raise ArgumentError, "erro já tratado pelo chamador"
      rescue ArgumentError
        Consultation.with_draft_admin { :ok }
      end
      expect(marker).to eq("off")
      expect_swap_refused(target)
      # `break` do bloco ainda é sucesso.
      [ 1 ].each { Consultation.with_draft_admin { break } }
      expect(marker).to eq("off")
      expect_swap_refused(target)
    end

    it "blocos aninhados: ao fechar o interno com sucesso a marca já volta a 'off' (o externo não herda)" do
      target = draft_of!(colleague, 1)
      Consultation.with_draft_admin do
        Consultation.with_draft_admin { :interno }
        expect(marker).to eq("off")
      end
      expect(marker).to eq("off")
      expect_swap_refused(target)
    end
  end

  describe "com a marca ligada, nada clínico finalizado muda" do
    let(:citizen) { verified_citizen!(1) }
    let(:finalized) { finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen) }
    let(:discarded) do
      orphan!(2, doctor!(unit)).tap { |c| ConsultationDrafts::Discard.call(consultation_id: c.id, reason: reason, by: admin).tap { |r| raise "descarte recusado" unless r.ok? } }
    end

    def as_draft_admin(&) = attempt { Consultation.with_draft_admin(&) }

    it "UPDATE de qualquer coluna da finalizada é recusado (texto, status, tipo, itens, sinais, identidade)" do
      finalized
      {
        subjective: "reescrito", plan: "reescrito", care_type: 6, systolic: 100, diastolic: 60,
        draft_items: { "conducts" => [ 1 ] }, author_user_id: colleague.id, cbo_code: "225125",
        status: "draft", finalized_at: nil
      }.each do |column, value|
        expect { as_draft_admin { finalized.update_columns(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes|identity columns never change/), column.to_s
      end
    end

    it "finalized → draft e finalized → discarded recusados (descarte nem 'zerando' o conteúdo)" do
      finalized
      expect { as_draft_admin { finalized.update_columns(status: "draft", finalized_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
      expect { as_draft_admin { finalized.update_columns(Consultation::CLINICAL_COLUMNS.index_with(nil).merge(status: "discarded", discarded_at: Time.current, draft_items: {})) } }
        .to raise_error(ActiveRecord::StatementInvalid, /finalized consultation never changes/)
      expect(finalized.reload).to have_attributes(status: "finalized", discarded_at: nil)
      expect(finalized.subjective).to be_present
    end

    it "DELETE de consulta (finalizada e descartada) recusado com a marca; o do rascunho já está na spec do guarda" do
      expect { as_draft_admin { finalized.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      expect { as_draft_admin { discarded.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
    end

    it "a descartada não muda com a marca (colunas clínicas, itens, status)" do
      discarded
      {
        subjective: "voltou", plan: "voltou", systolic: 120, care_type: 5, draft_items: { "conducts" => [ 1 ] },
        status: "finalized", finalized_at: Time.current
      }.each do |column, value|
        expect { as_draft_admin { discarded.update_columns(column => value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /discarded consultation never changes/), column.to_s
      end
      expect(discarded.reload.status).to eq("discarded")
    end

    it "adendos: UPDATE e DELETE recusados com a marca; INSERT de adendo em rascunho também" do
      addendum = ConsultationAddendum.create!(consultation: finalized, author_user: doctor, text: "MARCADOR-ADENDO",
                                              reason: "correção do exame pedido")
      expect { as_draft_admin { addendum.update_columns(reason: "outro motivo qualquer") } }
        .to raise_error(ActiveRecord::StatementInvalid, /UPDATE refused/)
      expect { as_draft_admin { addendum.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)

      draft = draft_of!(colleague, 3)
      expect { as_draft_admin { ConsultationAddendum.create!(consultation: draft, author_user: colleague, text: "x", reason: "correção do exame pedido") } }
        .to raise_error(ActiveRecord::StatementInvalid, /only a finalized consultation gains addenda/)
    end

    it "itens (problema, conduta, exame) de finalizada: UPDATE e DELETE recusados com a marca; INSERT sem adendo também" do
      finalized # a finalização grava um de cada (draft_body: T90, conduta 1, exame 0202010503)
      { ConsultationProblem => "consultation_problems", ConsultationConduct => "consultation_conducts",
        ConsultationExamRequest => "consultation_exam_requests" }.each do |model, table|
        row = model.where(consultation_id: finalized.id).first
        expect(row).to be_present, table
        expect { as_draft_admin { row.update_columns(created_at: 1.day.ago) } }
          .to raise_error(ActiveRecord::StatementInvalid, /append-only/), "#{table} UPDATE"
        expect { as_draft_admin { row.delete } }
          .to raise_error(ActiveRecord::StatementInvalid, /append-only/), "#{table} DELETE"
      end
      expect { as_draft_admin { ConsultationConduct.create!(consultation: finalized, code: 9, action: "add") } }
        .to raise_error(ActiveRecord::StatementInvalid, /only come with an addendum/)
    end
  end
end

# Fora da transação de fixture (conexão real, commits reais): grupo à parte,
# sem o `let!`/`before` do grupo acima, que COMMITARIAM unidades e usuários.
RSpec.describe "Marca rota.draft_admin: commits reais na mesma conexão" do
  self.use_transactional_tests = false

# A marca é SET LOCAL: morre no COMMIT. Nas specs transacionais tudo roda
# dentro de UMA transação de fixture, então o commit nunca acontece; aqui,
# sem fixture, as linhas são COMMITADAS de verdade (inseridas com os triggers
# desligados por session_replication_role = replica, como em
# clinical_record_invariants_spec.rb) e cada passo é uma transação real da
# MESMA conexão. Prova: nenhuma transação seguinte enxerga a marca, com ou sem
# transação aberta em volta do helper.

  let(:conn) { ApplicationRecord.connection }
  let(:ids) { { a: SecureRandom.uuid, b: SecureRandom.uuid } }
  let(:new_author) { SecureRandom.uuid }

  def in_city(&) = CityConnection.with(TEST_CITY_A, &)

  def insert_draft(id)
    conn.execute(<<~SQL)
      INSERT INTO consultations (id, attendance_id, patient_id, author_user_id, professional_link_id, cbo_code,
                                 started_at, created_at, updated_at)
      VALUES ('#{id}', gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), '225125',
              now(), now(), now())
    SQL
  end

  before do
    in_city do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        ids.each_value { |id| insert_draft(id) }
      end
    end
  end

  after do
    in_city do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        conn.execute("DELETE FROM consultations WHERE id IN ('#{ids[:a]}', '#{ids[:b]}')")
      end
    end
  end

  def discard_sql(id) = "UPDATE consultations SET status = 'discarded', discarded_at = now() WHERE id = '#{id}'"
  def swap_sql(id) = "UPDATE consultations SET author_user_id = '#{new_author}' WHERE id = '#{id}'"
  def status_of(id) = conn.select_value("SELECT status FROM consultations WHERE id = '#{id}'")
  def current_marker = conn.select_value("SELECT current_setting('rota.draft_admin', true)")

  it "o helper SEM transação aberta commita o descarte, e a transação seguinte da mesma conexão volta a ser recusada" do
    in_city do
      expect(conn.open_transactions).to eq(0) # fora de qualquer transação (autocommit do harness desligado)
      Consultation.with_draft_admin { conn.execute(discard_sql(ids[:a])) }
      expect(conn.open_transactions).to eq(0)
      expect(status_of(ids[:a])).to eq("discarded") # commitou: a marca valeu DENTRO do bloco

      expect(current_marker).not_to eq("on")
      expect { ApplicationRecord.transaction { conn.execute(discard_sql(ids[:b])) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarding a draft needs rota.draft_admin/)
      expect { ApplicationRecord.transaction { conn.execute(swap_sql(ids[:b])) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      expect(status_of(ids[:b])).to eq("draft")
    end
  end

  it "uma transação aberta pelo chamador: depois do bloco (ainda dentro dela) e na transação seguinte, a marca não vale" do
    in_city do
      ApplicationRecord.transaction do
        Consultation.with_draft_admin { conn.execute(discard_sql(ids[:a])) }
        expect(current_marker).to eq("off")
        expect { ApplicationRecord.transaction(requires_new: true) { conn.execute(swap_sql(ids[:b])) } }
          .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
      end
      expect(status_of(ids[:a])).to eq("discarded")

      expect(current_marker).not_to eq("on")
      expect { ApplicationRecord.transaction { conn.execute(swap_sql(ids[:b])) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    end
  end

  it "bloco que levanta, sem transação do chamador: nada commita e a transação seguinte da conexão segue recusada" do
    in_city do
      expect do
        Consultation.with_draft_admin do
          conn.execute(discard_sql(ids[:a]))
          raise ArgumentError, "falhou depois do UPDATE"
        end
      end.to raise_error(ArgumentError)
      expect(status_of(ids[:a])).to eq("draft")

      expect(current_marker).not_to eq("on")
      expect { ApplicationRecord.transaction { conn.execute(discard_sql(ids[:a])) } }
        .to raise_error(ActiveRecord::StatementInvalid, /discarding a draft needs rota.draft_admin/)
    end
  end
end
