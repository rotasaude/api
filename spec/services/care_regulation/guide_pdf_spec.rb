require "rails_helper"
require "pdf/reader"

# Módulo 26a, Task 12 (ADR 0044; contrato §3, §13 G8, G10, G12, G14): a guia de
# encaminhamento em PDF. Texto extraído com PDF::Reader; o paciente aparece sem
# o CPF (o CNS sai inteiro), o diagnóstico é o código presente (CID-10 ou CIAP-2)
# com a descrição da release ativa, a cor é a efetiva (sugerida enquanto não
# confirmada) e o autorizado traz prestador, mês e agendamento.
RSpec.describe CareRegulation::GuidePdf do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before { travel_to now }

  let!(:city) { regulation_city! }
  let!(:profile) { city_profile! }
  let(:long_justification) do
    "Hipertensão resistente a três fármacos, com lesão de órgão-alvo e necessidade de avaliação especializada " \
      "urgente para ajuste do esquema terapêutico e investigação de causas secundárias. " * 2
  end

  def text_of(request) = PDF::Reader.new(StringIO.new(described_class.call(request))).pages.map(&:text)
  def flat(request) = text_of(request).join(" ").gsub(/\s+/, " ")

  it "devolve bytes de PDF com o título e o rodapé de regulação em toda página" do
    request = regulation_request!(justification: long_justification)
    bytes = described_class.call(request)
    expect(bytes).to start_with("%PDF")
    reader = PDF::Reader.new(StringIO.new(bytes))
    expect(reader.info[:Title]).to eq("Guia de encaminhamento")
    reader.pages.each { |page| expect(page.text.gsub(/\s+/, " ")).to include("não é autorização do sistema do estado") }
  end

  it "pedido pendente: cabeçalho, paciente, alvo, CID-10 com descrição, justificativa inteira, cor sugerida, prazo e solicitante" do
    request = regulation_request!(justification: long_justification, suggested_color: "yellow")
    text = flat(request)
    expect(text).to include(profile.name, "Guia de encaminhamento", "Nº #{request.id[0, 8]}", "28/10/2026")
    expect(text).to include("Maria Aparecida", "Nascimento", "Sexo")
    expect(text).to include("Cardiologia", "225120")
    expect(text).to include("CID-10: I10", "Hipertensão essencial (primária)")
    expect(text).not_to include("CIAP-2")
    expect(text).to include(long_justification.strip.gsub(/\s+/, " "))
    expect(text).to include("Amarelo", "sugerida", "Prazo: 27/11/2026")
    expect(text).to include(request.requester_user.professional.professional_name, "225125", request.requester_unit.name)
    expect(text).to include("Aguardando regulação")
    expect(text).not_to include("RASCUNHO")
  end

  it "a justificativa longa quebra em mais de uma linha" do
    request = regulation_request!(justification: long_justification)
    lines = text_of(request).first.lines.map(&:strip).compact_blank
    from = lines.index { |l| l.start_with?("Justificativa:") }
    upto = lines.index { |l| l.start_with?("Prioridade:") }
    expect(from).not_to be_nil
    expect(upto - from).to be >= 3
  end

  it "nunca imprime o CPF (cru, formatado nem em dígitos soltos); o CNS sai inteiro" do
    request = regulation_request!
    patient = request.patient
    patient.update!(cns: "700000000000005")
    pages = text_of(request)
    text = pages.join(" ")
    cpf = patient.cpf
    formatted = cpf.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4')
    expect([ text, text.gsub(/\D/, "") ]).to all(satisfy { |t| !t.include?(cpf) && !t.include?(formatted) })
    expect(text.gsub(/\D/, "")).to include("700000000000005")
  end

  it "paciente sem CPF: o CNS inteiro e nenhuma linha de CPF" do
    request = regulation_request!
    allow(request).to receive(:patient).and_return(registry_no_cpf_patient!(cns: "700000000000005"))
    text = flat(request)
    expect(text.gsub(/\D/, "")).to include("700000000000005")
    expect(text).not_to include("CPF")
  end

  it "órgão de saúde abaixo da cidade quando a plataforma tem o valor; sem ele, nenhuma linha extra" do
    request = regulation_request!
    expect(flat(request)).to include("#{profile.name} Guia de encaminhamento")
    expect(UpdateCityIdentity.call(city: Current.city, health_department_name: "Secretaria Municipal da Saúde")).to be_ok
    expect(flat(request)).to include("#{profile.name} Secretaria Municipal da Saúde Guia de encaminhamento")
  end

  it "pedido de enfermeira só com CIAP-2: mostra CIAP-2, K86 e a descrição, e não mostra CID-10" do
    unit = create_unit("UBS Enfermagem #{SecureRandom.hex(2)}")
    expect(CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225120", by: regulation_admin!)).to be_ok
    request = regulation_request!(unit: unit, doctor: nurse!(unit), cid10: nil, ciap2: "K86")
    text = flat(request)
    expect(text).to include("CIAP-2: K86", "Hipertensão sem complicações")
    expect(text).not_to include("CID-10")
  end

  it "pedido da médica com os dois códigos mostra os dois" do
    request = regulation_request!(cid10: "I10", ciap2: "K86")
    text = flat(request)
    expect(text).to include("CID-10: I10", "Hipertensão essencial (primária)", "CIAP-2: K86", "Hipertensão sem complicações")
  end

  it "descrição ausente da release ativa: só o código" do
    request = regulation_request!
    allow(ClinicalTerms).to receive(:find).and_return(nil)
    text = flat(request)
    expect(text).to include("CID-10: I10")
    expect(text).not_to include("I10 —")
  end

  it "cor confirmada pelo regulador: a cor efetiva sem a marca 'sugerida'" do
    request = regulation_request!(suggested_color: "yellow")
    request.update!(color: "red")
    text = flat(request)
    expect(text).to include("Vermelho")
    expect(text).not_to include("sugerida")
  end

  it "pedido autorizado: prestador, mês 10/2026 e a autorização no lugar de 'Aguardando regulação'" do
    provider = external_provider!(kind: "contracted", name: "Clínica de Olhos Araucária")
    request = reauthorize!(regulation_request!, offer: offer!(provider: provider))
    text = flat(request)
    expect(text).to include("Autorização", "Clínica de Olhos Araucária", provider.cnes, "10/2026")
    expect(text).not_to include("Aguardando regulação")
  end

  it "agendado: data (horário) e local" do
    provider = external_provider!(kind: "contracted", name: "Clínica de Olhos Araucária")
    request = reauthorize!(regulation_request!, offer: offer!(provider: provider))
    scheduled = CareRegulation::ScheduleExternal.call(request: request, at: Time.zone.local(2026, 11, 3, 14, 30).iso8601,
                                              place: "Rua das Flores, 100", notes: nil, version: request.version,
                                              by: regulation_regulator!)
    raise "agendamento recusado: #{scheduled.reason}" if scheduled.failure?

    text = flat(request.reload)
    expect(text).to include("03/11/2026 14:30", "Rua das Flores, 100")
  end

  it "regulado pelo estado: marca e o número externo, sem autorização municipal" do
    request = regulation_request!(status: "external")
    marked = CareRegulation::MarkExternal.call(request: request, system: "sisreg", number: "123456789", version: request.version,
                                               by: regulation_regulator!)
    raise "marcação recusada: #{marked.reason}" if marked.failure?

    text = flat(request.reload)
    expect(text).to include("regulado pelo estado", "SISREG", "123456789")
    expect(text).not_to include("Aguardando regulação")
  end

  it "rascunho: a marca 'RASCUNHO — sem validade'" do
    request = regulation_request!(status: "draft")
    expect(flat(request)).to include("RASCUNHO", "sem validade")
  end

  it "símbolo fora da fonte embutida não derruba o impresso" do
    request = regulation_request!(justification: "Paciente com ≥ 3 crises 🌼 por semana e piora progressiva")
    expect(flat(request)).to include("Paciente com ? 3 crises ?")
  end
end
