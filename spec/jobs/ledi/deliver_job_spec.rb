# spec/jobs/ledi/deliver_job_spec.rb
require "rails_helper"

# Spec §6.4 / §9 "Envio": tabela de casos. O PEC é o FakePec
# (spec/support/ledi_helpers.rb).
RSpec.describe Ledi::DeliverJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ledi_ready!(register_test_city!, pec_url: "https://pec.a.test") }
  let(:pec) { FakePec.for("https://pec.a.test") }

  before do
    stub_pec!
    allow(Ledi::Observations).to receive(:duplicate_marker).and_return(nil)
    allow(Ledi::Observations).to receive(:session_expired_statuses).and_return([ 401 ])
  end

  def enqueue!(n = 1)
    allow(Ledi::DeliverJob).to receive(:perform_later)
    Array.new(n) do
      Ledi::Enqueue.call(Ledi::Fichas::Synthetic.new(cnes: "1234567", ine: "0000123456",
                                                     professional_cns: "700000000000005", cbo: "225142",
                                                     attended_at: Time.current), city: city)
    end
  end

  def run! = described_class.perform_now
  def events(name) = DomainEvent.where(name: name).map(&:payload)

  it "200/201: accepted, payload apagado, evento só com ids, um login para o lote" do
    entries = enqueue!(2)
    pec.delivery_replies = [ [ 200, "" ], [ 201, "" ] ]
    run!
    entries.each(&:reload)
    expect(entries.map(&:status)).to eq(%w[accepted accepted])
    expect(entries.map(&:payload)).to eq([ nil, nil ])
    expect(pec.logins.size).to eq(1)
    expect(pec.deliveries.map { |d| d[:filename] }).to eq(entries.map { |e| "#{e.uuid}.esus" })
    expect(events("ledi.ficha_accepted")).to contain_exactly(
      *entries.map { |e| { "outbox_id" => e.id, "ficha_type" => "procedimento", "competence" => e.competence } }
    )
  end

  it "400: rejected com a mensagem mascarada, sem nova tentativa sozinha" do
    entry = enqueue!.first
    pec.delivery_replies = [ [ 400, { descricaoErro: "Erro de validação",
                                       errosValidacao: { cpfCidadao: "CPF 12345678909 inválido" } }.to_json ] ]
    run!
    expect(entry.reload.slice(:status, :last_error, :attempts))
      .to eq("status" => "rejected", "last_error" => "Erro de validação; cpfCidadao: CPF [número] inválido", "attempts" => 1)
    expect(events("ledi.ficha_rejected").sole).to eq("outbox_id" => entry.id, "ficha_type" => "procedimento",
                                                      "competence" => entry.competence)
    run!
    expect(pec.deliveries.size).to eq(1)
  end

  it "5xx e timeout: pending com espera crescente; payload continua" do
    first, second = enqueue!(2)
    pec.delivery_replies = [ [ 503, "" ], Ledi::PecClient::Unreachable ]
    freeze_time(1.second.from_now) do # freeze_time trunca os microssegundos: sem folga a fila ainda não venceu
      run!
      expect(first.reload.slice(:status, :attempts, :last_error)).to eq("status" => "pending", "attempts" => 1,
                                                                        "last_error" => "HTTP 503")
      expect(first.next_attempt_at).to eq(1.minute.from_now)
      expect(second.reload.last_error).to eq("PEC inacessível")
      expect(second.bytes).to be_present
    end
  end

  # R32: uma ficha que levanta erro inesperado não derruba nem trava o lote.
  it "erro inesperado numa ficha: ela volta a pending com a classe do erro e o resto do lote segue" do
    first, second, third = enqueue!(3)
    pec.delivery_replies = [ [ 201, "" ], RuntimeError.new("segredo"), [ 201, "" ] ]
    run!
    expect(first.reload.status).to eq("accepted")
    expect(second.reload.slice(:status, :attempts, :last_error))
      .to eq("status" => "pending", "attempts" => 1, "last_error" => "erro interno (RuntimeError)")
    expect(second.last_error).not_to include("segredo")
    expect(third.reload.status).to eq("accepted")
  end

  it "24 h depois da primeira tentativa: failed" do
    entry = enqueue!.first
    pec.delivery_replies = [ [ 500, "" ] ]
    run!
    entry.reload.update_columns(next_attempt_at: 1.minute.ago, first_attempt_at: 25.hours.ago)
    pec.delivery_replies = [ [ 500, "" ] ]
    run!
    expect(entry.reload.slice(:status, :attempts)).to eq("status" => "failed", "attempts" => 2)
  end

  it "401: novo login uma vez e a mesma ficha é aceita" do
    entry = enqueue!.first
    pec.delivery_replies = [ [ 401, "" ], [ 201, "" ] ]
    run!
    expect(entry.reload.status).to eq("accepted")
    expect(pec.logins.size).to eq(2)
  end

  it "401 duas vezes: credencial unauthorized, lote volta a pending sem tentativa, envio pausado" do
    entries = enqueue!(2)
    pec.delivery_replies = [ [ 401, "" ], [ 401, "" ] ]
    run!
    expect(entries.map { |e| e.reload.slice(:status, :attempts) }).to all(eq("status" => "pending", "attempts" => 0))
    credential = IntegrationCredential.find_by!(kind: "ledi")
    expect(credential.last_check_status).to eq("unauthorized")
    expect(credential.last_check_message).to eq(Ledi::Delivery::PAUSE_MESSAGE)
    expect(credential.last_check_message).not_to include("segredo-ledi")

    pec.delivery_replies = []
    allow(Platform::Features).to receive(:usable?).and_call_original
    run!
    expect(pec.deliveries.size).to eq(2) # pausado: usable? é falso com credential_unauthorized
  end

  it "login recusado: pausa direto" do
    enqueue!
    pec.login_replies = [ Ledi::PecClient::Unauthorized ]
    run!
    expect(IntegrationCredential.find_by!(kind: "ledi").last_check_status).to eq("unauthorized")
    expect(pec.deliveries).to be_empty
    expect(LediOutboxEntry.pluck(:status, :attempts)).to eq([ [ "pending", 0 ] ])
  end

  # Review Focus 2.
  it "pausada não envia; voltou a ok (credencial nova), envia — sem reaproveitar o cookie antigo" do
    entry = enqueue!.first
    pec.delivery_replies = [ [ 401, "" ], [ 401, "" ] ]
    run!
    expect(entry.reload.status).to eq("pending")

    travel 1.second
    IntegrationCredential.find_by!(kind: "ledi").update!(secret: { "username" => "rota2", "password" => "nova" },
                                                         set_at: Time.current, last_check_status: "ok")
    pec.delivery_replies = [ [ 201, "" ] ]
    run!
    expect(entry.reload.status).to eq("accepted")
    expect(pec.logins.last[:username]).to eq("rota2")
    expect(pec.deliveries.last[:cookie]).to eq("JSESSIONID=fake-#{pec.logins.size}")
  end

  it "o cookie fica em cache entre execuções da mesma credencial" do
    enqueue!
    run!
    enqueue!
    run!
    expect(pec.logins.size).to eq(1)
  end

  it "interruptor desligado ou record_mode off: nada sai" do
    enqueue!(2)
    ledi_off!(city)
    run!
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "off")
    run!
    expect(pec.deliveries).to be_empty
    expect(LediOutboxEntry.distinct.pluck(:status)).to eq([ "pending" ])
  end

  it "está no recurring.yml, a cada minuto, na fila default" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "ledi_deliver")
    expect(task).to eq("class" => "Ledi::DeliverJob", "queue" => "default", "schedule" => "every minute")
  end
end
