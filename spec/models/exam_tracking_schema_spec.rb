require "rails_helper"

# ADR 0036 (Invariantes; Desvio 6): a trilha só cresce; o cache da situação
# só muda com um evento da mesma transação; o resultado não muda; o arquivo
# só é apagado se nunca foi usado; valores e PDF cifrados.
RSpec.describe "Banco do rastreamento de exames" do
  before { exam_city! }

  let(:unit) { create_unit("UBS Exames") }
  let(:doctor) { doctor!(unit) }
  let(:order) { exam_order!(patient: exam_patient!(1).first, unit: unit, requester: doctor) }

  it "exam_order_events é só acréscimo" do
    event = order.events.first
    expect { event.update!(occurred_at: 1.day.ago) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { event.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  # Dentro da fixture transacional todo evento tem o txid do teste: a recusa
  # "sem evento da mesma transação" é provada no describe não transacional abaixo.
  it "o cache muda com o evento; a identidade nunca; nunca some" do
    ApplicationRecord.transaction do
      ExamOrderEvent.create!(exam_order: order, kind: "scheduled", actor_user: doctor, occurred_at: Time.current)
      order.update!(status: "scheduled", status_changed_at: Time.current)
    end
    expect(order.reload.status).to eq("scheduled")
    expect do
      ApplicationRecord.transaction do
        ExamOrderEvent.create!(exam_order: order, kind: "collected", actor_user: doctor, occurred_at: Time.current)
        order.update!(sigtap_code: "0202020380")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /identity never changes/)
    expect { order.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
  end

  it "pedido nasce aguardando; banco recusa solicitante ausente e origem incoerente" do
    expect { exam_order!(patient: order.patient, unit: unit, requester: doctor, status: :scheduled) }
      .to raise_error(ActiveRecord::StatementInvalid, /born awaiting/)
    attrs = order.attributes.except("id", "short_code", "created_at", "updated_at").merge("short_code" => "ABCDEFGH23")
    expect { ExamOrder.create!(attrs.merge("requester_user_id" => nil, "requester_name" => nil)) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_exam_orders_requester/)
    expect { ExamOrder.create!(attrs.merge("origin" => "consultation")) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_exam_orders_consultation/)
  end

  it "resultado imutável e cifrado; arquivo usado não some" do
    file = pdf_file!(user: doctor)
    result = ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order",
                                source: "unit", pdf_file: file, values: [ { "key" => "hba1c", "value" => "9.1" } ].to_json,
                                released_on: Time.zone.today, laboratory_name: "Lab", critical: false, registered_by_user: doctor)
    raw = ApplicationRecord.connection.select_value("SELECT values FROM exam_results WHERE id = #{ApplicationRecord.connection.quote(result.id)}")
    expect(raw).not_to include("9.1")
    expect(result.reload.values_list.first["value"]).to eq("9.1")
    expect(result.inspect).not_to include("9.1")
    expect { result.update!(critical: true) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    file.update!(consumed_at: Time.current)
    expect { file.destroy! }.to raise_error(ActiveRecord::StatementInvalid, /consumed/)
    expect(ExamFile.find(file.id).bytes).to eq(ExamHelpers::PDF_BYTES)
    expect(ApplicationRecord.connection.select_value("SELECT data FROM exam_files WHERE id = #{ApplicationRecord.connection.quote(file.id)}"))
      .not_to include(Base64.strict_encode64(ExamHelpers::PDF_BYTES))
  end

  # A35: portal grava prestador E funcionário; sem ator só o system (escalated).
  # A31: um escalated por (pedido, motivo) também no banco.
  it "atores do evento e do resultado (A35); escalonamento único por motivo (A31)" do
    provider = exam_provider!(name: "Lab Atores")
    both = ExamOrderEvent.create!(exam_order: order, kind: "requested", actor_user: doctor, actor_provider: provider, occurred_at: Time.current)
    expect(both).to be_persisted
    expect { ExamOrderEvent.create!(exam_order: order, kind: "requested", occurred_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_exam_order_events_actor/)
    ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: "overdue", occurred_at: Time.current)
    ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: "critical", occurred_at: Time.current)
    expect { ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: "overdue", occurred_at: Time.current) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_exam_order_events_escalation_once/)
    attrs = { exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order", source: "provider",
              values: "[]", released_on: Time.zone.today, laboratory_name: "Lab", critical: false }
    expect { ExamResult.create!(attrs.merge(pdf_file: pdf_file!)) }.to raise_error(ActiveRecord::StatementInvalid, /ck_exam_results_registrant/)
    expect(ExamResult.create!(attrs.merge(pdf_file: pdf_file!, registered_by_user: doctor, registered_by_provider: provider))).to be_persisted
  end

  it "papéis novos no banco e privilegiados" do
    user = staff_with("regulacao-#{SecureRandom.hex(3)}@cidade.gov.br", "exam_regulator", "exam_provider")
    expect(user.has_role?("exam_regulator")).to be(true)
    expect(Membership::PRIVILEGED_ROLES).to include("exam_regulator", "exam_provider")
  end

  it "prioridade no pedido do 19a, padrão routine" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect(consultation.exam_requests.first.priority).to eq("routine")
  end
end

# Mutação: tirar `e.txid = txid_current()` de rota_exam_order_guard. Fora de
# fixture transacional (como o teste do patient_problems do 19a): o evento
# commita numa transação e o UPDATE vem de outra. Linhas sintéticas com os
# triggers desligados (replica dispensa as FKs).
RSpec.describe "exam_orders: evento de outra transação não basta (ADR 0036)" do
  self.use_transactional_tests = false

  let(:order_id) { SecureRandom.uuid }
  let(:conn) { ApplicationRecord.connection }

  def as_replica(*statements)
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        conn.execute("SET LOCAL session_replication_role = replica")
        statements.each { |sql| conn.execute(sql) }
      end
    end
  end

  before do
    as_replica(<<~SQL, "INSERT INTO exam_order_events (exam_order_id, kind, actor_user_id, occurred_at, created_at) VALUES ('#{order_id}', 'requested', gen_random_uuid(), now(), now())")
      INSERT INTO exam_orders (id, patient_id, sigtap_code, sigtap_competence, priority, requester_name, unit_id, origin, short_code,
                               status, status_changed_at, created_at, updated_at)
      VALUES ('#{order_id}', gen_random_uuid(), '0202010503', '202610', 'routine', 'x', gen_random_uuid(), 'pec', 'ABCDEFGH23',
              'awaiting_schedule', now(), now(), now())
    SQL
  end

  after do
    as_replica("DELETE FROM exam_order_events WHERE exam_order_id = '#{order_id}'", "DELETE FROM exam_orders WHERE id = '#{order_id}'")
  end

  it "recusa o UPDATE do cache quando o evento foi commitado em outra transação" do
    CityConnection.with(TEST_CITY_A) do
      expect { ApplicationRecord.transaction { conn.execute("UPDATE exam_orders SET status = 'scheduled' WHERE id = '#{order_id}'") } }
        .to raise_error(ActiveRecord::StatementInvalid, /status changes only with an event of the same transaction/)
    end
  end

  it "aceita o mesmo UPDATE com evento da mesma transação (controle)" do
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        # Evento do system (sem ator, A35) para não depender de FK de usuário real.
        conn.execute("INSERT INTO exam_order_events (exam_order_id, kind, escalation_reason, occurred_at, created_at) " \
                     "VALUES ('#{order_id}', 'escalated', 'overdue', now(), now())")
        conn.execute("UPDATE exam_orders SET status = 'scheduled' WHERE id = '#{order_id}'")
        expect(conn.select_value("SELECT status FROM exam_orders WHERE id = '#{order_id}'")).to eq("scheduled")
        raise ActiveRecord::Rollback
      end
    end
  end
end
