require "rails_helper"

# Prova técnica do módulo 16 (spec §6.1). Fala com o PEC local de
# deploy/development/pec (docs/operacao/pec-local-dev.md). Variáveis (só no shell):
#   LEDI_PEC_URL, LEDI_PEC_CA_FILE, LEDI_PEC_USERNAME, LEDI_PEC_PASSWORD,
#   LEDI_PROOF_CNES, LEDI_PROOF_INE, LEDI_PROOF_CNS, LEDI_PROOF_CBO, LEDI_PROOF_IBGE.
# Cada exemplo imprime o que o PEC respondeu: é daí que sai pec_observations.yml.
RSpec.describe "Prova técnica LEDI contra o PEC local", :pec do
  around do |example|
    WebMock.disable! if defined?(WebMock)
    example.run
  ensure
    WebMock.enable! if defined?(WebMock)
  end

  before(:all) { Ledi::Version.load! }

  let(:client) do
    Ledi::PecClient.new(base_url: ENV.fetch("LEDI_PEC_URL"), username: ENV.fetch("LEDI_PEC_USERNAME"),
                        password: ENV.fetch("LEDI_PEC_PASSWORD"))
  end
  let(:cookie) { client.login.cookie }
  let(:serializer) { Thrift::Serializer.new(Thrift::BinaryProtocolFactory.new) }
  let(:ras) { Br::Gov::Saude::Esusab::Ras }
  let(:transp) { Br::Gov::Saude::Esusab::Dadotransp }

  def ms(time) = (time.to_f * 1000).to_i

  def ficha(uuid, cnes: ENV.fetch("LEDI_PROOF_CNES"))
    now = Time.current.change(min: 0) - 1.hour
    child = ras::Atendprocedimentos::FichaProcedimentoChildThrift.new(
      dtNascimento: ms(Time.zone.local(1980, 5, 10)), sexo: 1, localAtendimento: 1, turno: 1,
      cpfCidadao: "12345678909", stCidadaoNaoPossuiCpf: false, procedimentos: [ "0301100039" ],
      dataHoraInicialAtendimento: ms(now), dataHoraFinalAtendimento: ms(now + 10.minutes)
    )
    header = ras::Common::UnicaLotacaoHeaderThrift.new(
      profissionalCNS: ENV.fetch("LEDI_PROOF_CNS"), cboCodigo_2002: ENV.fetch("LEDI_PROOF_CBO"), cnes: cnes,
      ine: ENV.fetch("LEDI_PROOF_INE"), dataAtendimento: ms(now), codigoIbgeMunicipio: ENV.fetch("LEDI_PROOF_IBGE")
    )
    ras::Atendprocedimentos::FichaProcedimentoMasterThrift.new(
      uuidFicha: uuid, tpCdsOrigem: 3, headerTransport: header, atendProcedimentos: [ child ]
    )
  end

  def transport(uuid, cnes: ENV.fetch("LEDI_PROOF_CNES"))
    installation = transp::DadoInstalacaoThrift.new(
      contraChave: "Rota Saúde - prova", uuidInstalacao: "rota-saude-dev-proof", cpfOuCnpj: "11222333000181",
      nomeOuRazaoSocial: "Rota Saúde dev", email: "dev@rotasaude.app"
    )
    transp::DadoTransporteThrift.new(
      uuidDadoSerializado: uuid, tipoDadoSerializado: 7, cnesDadoSerializado: cnes,
      codIbge: ENV.fetch("LEDI_PROOF_IBGE"), ineDadoSerializado: ENV.fetch("LEDI_PROOF_INE"),
      dadoSerializado: serializer.serialize(ficha(uuid, cnes: cnes)), remetente: installation,
      originadora: installation, versao: transp::VersaoThrift.new(major: 8, minor: 7, revision: 0)
    )
  end

  def send!(uuid, cookie_value: cookie, cnes: ENV.fetch("LEDI_PROOF_CNES"))
    bytes = serializer.serialize(transport(uuid, cnes: cnes))
    reply = client.deliver(cookie: cookie_value, filename: "#{uuid}.esus", bytes: bytes)
    puts "[pec] #{uuid} → #{reply.status} #{reply.body.to_s.truncate(300).inspect}"
    reply
  end

  def new_uuid = "#{ENV.fetch('LEDI_PROOF_CNES')}-#{SecureRandom.uuid}"

  it "aceita a ficha sintética (critério de saída) e responde ao reenvio do mesmo uuid" do
    uuid = new_uuid
    expect(send!(uuid).status).to be_between(200, 299)
    send!(uuid) # duplicate_after_accept: registre status e corpo
  end

  it "recusa ficha com CNES fora do município (formato do 400) e responde ao reenvio do mesmo uuid" do
    uuid = new_uuid
    first = send!(uuid, cnes: "0000000")
    expect(first.status).to eq(400)
    send!(uuid) # resend_after_rejection: mesmo uuid, agora com o CNES certo
  end

  it "sessão inválida: registre o status" do
    send!(new_uuid, cookie_value: "JSESSIONID=invalida")
  end

  it "login com senha errada: registre a exceção (e o status, se Failed)" do
    wrong = Ledi::PecClient.new(base_url: ENV.fetch("LEDI_PEC_URL"), username: ENV.fetch("LEDI_PEC_USERNAME"),
                                password: "senha-errada")
    wrong.login
  rescue Ledi::PecClient::Error => e
    puts "[pec] login recusado → #{e.class.name} #{e.respond_to?(:status) ? e.status : ''}"
    expect(e).to be_a(Ledi::PecClient::Unauthorized)
  end
end
