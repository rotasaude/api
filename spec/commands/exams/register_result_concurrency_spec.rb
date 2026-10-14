require "rails_helper"

# Review Focus 2 (F-21.8): a unidade e o portal registrando o mesmo exame ao
# mesmo tempo, e a unidade cancelando enquanto o laboratório envia, em
# conexões reais. Um resultado só; o outro leva result_already_registered ou
# invalid_transition; nunca um pedido cancelado com resultado. Threads reais
# contra TEST_CITY_A (sem fixture transacional), como cancel_lock_spec; a
# plataforma não é tocada (o serviço não consulta interruptor).
RSpec.describe "Resultado do exame sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  before do
    @rows = in_city do
      @empty = empty_tables
      unit = create_unit("UBS Disputa")
      doctor = doctor!(unit)
      exam_catalog_item!
      provider = exam_provider!(name: "Lab Disputa")
      lab = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider")
      ExamProviderUser.create!(exam_provider: provider, user: lab)
      reception = staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier")
      order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor, provider: provider)
      ApplicationRecord.transaction do
        order.lock!
        Exams::Transition.call(order: order, kind: "scheduled", actor_user: doctor,
                               changes: { scheduled_at: 1.day.from_now, scheduled_place: "Lab" })
      end
      { order_id: order.id, doctor_id: doctor.id, lab_id: lab.id, reception_id: reception.id }
    end
  end

  after do
    3.times { release << true }
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

  # Cada thread com o SEU objeto do pedido, lido antes da disputa (velho).
  def register(source, user_id)
    user = User.find(user_id)
    Exams::RegisterResult.call(order: ExamOrder.find(@rows[:order_id]), source: source, file: pdf_file!(user: user),
                               released_on: Time.zone.today.iso8601, laboratory_name: "Lab Disputa", critical: false,
                               values: [ { "key" => "hba1c", "value" => "6.1" } ], by_user: user)
  end

  def cancel = Exams::Steps.cancel(order: ExamOrder.find(@rows[:order_id]), reason: "Feito em outro serviço", actor_user: User.find(@rows[:doctor_id]))

  # A primeira operação segura a transação aberta (pedido travado) até o
  # release; a segunda começa enquanto isso e tem de esperar a trava.
  def race(first, second)
    holding = Queue.new
    first_out = Queue.new
    threads << holder = Thread.new do
      in_city do
        ApplicationRecord.transaction do
          first_out << first.call
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
        end
      end
    end
    holding.pop(timeout: 5) or raise "a primeira não travou o pedido"

    second_out = Queue.new
    threads << waiter = Thread.new { second_out << in_city { second.call } }
    expect(waiter.join(1)).to be_nil # esperando a trava do pedido
    release << true
    expect(holder.join(5)).to be(holder)
    expect(waiter.join(5)).to be(waiter)
    [ first_out.pop(timeout: 1), second_out.pop(timeout: 1) ]
  end

  def stored = in_city { [ ExamOrder.find(@rows[:order_id]).status, ExamResult.where(exam_order_id: @rows[:order_id]).pluck(:source) ] }

  it "unidade e portal ao mesmo tempo: um resultado; o outro result_already_registered" do
    first, second = race(-> { register("unit", @rows[:reception_id]) }, -> { register("provider", @rows[:lab_id]) })
    expect(first).to be_ok
    expect(second.reason).to eq(:result_already_registered)
    expect(stored).to eq([ "resulted", %w[unit] ])
  end

  it "a unidade cancela enquanto o laboratório envia: o resultado vê o cancelado (409)" do
    first, second = race(-> { cancel }, -> { register("provider", @rows[:lab_id]) })
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :invalid_transition, { status: "cancelled" } ])
    expect(stored).to eq([ "cancelled", [] ])
  end

  it "o laboratório envia enquanto a unidade cancela: o cancelamento vê o resultado (409)" do
    first, second = race(-> { register("provider", @rows[:lab_id]) }, -> { cancel })
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :invalid_transition, { status: "resulted" } ])
    expect(stored).to eq([ "resulted", %w[provider] ])
  end

  it "sem trava de quem chama, as duas portas simultâneas dão exatamente um resultado" do
    go = Queue.new
    outs = Queue.new
    2.times do |i|
      threads << Thread.new do
        in_city do
          go.pop(timeout: 5)
          outs << (i.zero? ? register("unit", @rows[:reception_id]) : register("provider", @rows[:lab_id]))
        end
      end
    end
    2.times { go << true }
    threads.each { |t| expect(t.join(10)).to be(t) }
    results = [ outs.pop(timeout: 1), outs.pop(timeout: 1) ]
    expect(results.count(&:ok?)).to eq(1)
    expect(results.reject(&:ok?).map(&:reason)).to eq([ :result_already_registered ])
    expect(stored.last.size).to eq(1)
  end
end
