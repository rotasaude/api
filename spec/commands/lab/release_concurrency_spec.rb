require "rails_helper"

# Review Focus 2: dois liberadores liberando o mesmo item ao mesmo tempo, e
# a unidade cancelando o exame enquanto o laboratório libera (nas duas
# ordens; E2/B38: requisição → itens → pedido nos dois lados, sem deadlock).
# Um laudo, um resultado no 21a; o outro leva invalid_transition; nunca um
# exame cancelado com resultado.
RSpec.describe "Liberação sob disputa" do
  self.use_transactional_tests = false

  let(:release_gate) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |t| %w[schema_migrations ar_internal_metadata].include?(t) }
              .select { |t| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)})") }
  end

  before do
    # Sem fixture transacional, a plataforma não é tocada: a competência SIGTAP
    # do pedido vem de um dublê (o resto é a cidade, limpa no after).
    allow(ClinicalTerms::SigtapExams).to receive(:find).and_return(Struct.new(:competence).new(Time.zone.today.strftime("%Y%m")))
    @rows = in_city do
      @empty = empty_tables
      provider = lab_provider!
      a = lab_releaser!(provider, lead: true)
      b = lab_releaser!(provider)
      req = received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ])
      item = type!(req.items.first, { glicose: "98" })
      { req_id: req.id, item_id: item.id, a: a.id, b: b.id, order_id: item.exam_order_id, doctor: item.exam_order.requester_user_id }
    end
  end

  after do
    3.times { release_gate << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        @empty.to_a.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
  end

  def release_by(user_id)
    user = User.find(user_id)
    Lab::Release.call(requisition: LabRequisition.find(@rows[:req_id]), item_ids: [ @rows[:item_id] ], signature: "advanced",
                      totp: ROTP::TOTP.new(user.otp_secret).now, by: user)
  end

  def cancel = Exams::Steps.cancel(order: ExamOrder.find(@rows[:order_id]), reason: "Feito em outro serviço", actor_user: User.find(@rows[:doctor]))

  # A primeira segura a transação aberta até o release_gate; a segunda espera a trava.
  def race(first, second)
    holding = Queue.new
    first_out = Queue.new
    threads << Thread.new do
      in_city do
        ApplicationRecord.transaction do
          first_out << first.call
          holding << true
          release_gate.pop(timeout: 10) or raise "timeout"
        end
      end
    end
    holding.pop(timeout: 10) or raise "timeout"
    second_out = Queue.new
    threads << Thread.new { in_city { second_out << second.call } }
    sleep 0.3
    release_gate << true
    [ first_out.pop(timeout: 10), second_out.pop(timeout: 10) ]
  end

  it "dois liberadores: um laudo, um resultado; o outro 409" do
    first, second = race(-> { release_by(@rows[:a]) }, -> { release_by(@rows[:b]) })
    expect(first).to be_ok
    expect(second.reason).to eq(:invalid_transition)
    in_city do
      expect(LabReportItem.where(lab_requisition_item_id: @rows[:item_id]).count).to eq(1)
      expect(ExamResult.where(exam_order_id: @rows[:order_id]).count).to eq(1)
    end
  end

  it "liberação × cancelamento: quem vem depois perde; nunca cancelado com resultado" do
    first, second = race(-> { release_by(@rows[:a]) }, -> { cancel })
    expect(first).to be_ok
    expect(second.reason).to eq(:invalid_transition)
    in_city do
      order = ExamOrder.find(@rows[:order_id])
      expect(order.status).to eq("resulted")
      expect(ExamResult.where(exam_order_id: order.id).count).to eq(1)
    end
  end

  it "cancelamento × liberação: o cancelamento segura as travas na mesma ordem; a liberação espera e passa" do
    first, second = race(-> { cancel }, -> { release_by(@rows[:a]) })
    expect(first.reason).to eq(:invalid_transition) # item digitado não cancela (B12)
    expect(second).to be_ok
    in_city do
      order = ExamOrder.find(@rows[:order_id])
      expect(order.status).to eq("resulted")
      expect(LabRequisitionItem.find(@rows[:item_id]).status).to eq("released")
    end
  end
end
