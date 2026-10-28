require "rails_helper"

# Módulo 25, Task 15 (contrato §7, §14; K10): a ficha de notificação individual
# no formato do Sinan, para digitação. O texto sai do PDF com PDF::Reader.
RSpec.describe Surveillance::Pdf do
  before { surveillance_city! }

  let(:unit) { create_unit("UBS Vigia").tap { |u| u.update!(cnes: "2345678") } }
  let(:doctor) { doctor!(unit) }
  let(:patient) do
    surveillance_patient!(1).tap { |p| p.update!(race_color: "03", cns: valid_cns(1), mother_name: "Joana da Silva") }
  end
  let(:suspected_at) { Time.zone.local(2026, 10, 20, 12) }
  let(:notification) { notification!(patient: patient, unit: unit, by: doctor, suspected_at: suspected_at, symptoms_on: Date.new(2026, 10, 18)) }

  def reader(bytes) = PDF::Reader.new(StringIO.new(bytes))
  def text_of(bytes) = reader(bytes).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  it "traz o título, o agravo com o CID, os números de campo, os códigos com a descrição e as datas dd/mm/aaaa" do
    text = text_of(described_class.call(notification))
    cid = Surveillance::Diseases.find("dengue").cid10.first

    expect(text).to include("Ficha de Notificação Individual (Sinan) — para digitação", "1 Tipo de notificação: 2 — Individual")
    expect(text).to include("2 Agravo/doença:", "Dengue", "CID-10 #{cid}")
    expect(text).to include("3 Data da notificação: 20/10/2026", "7 Data dos primeiros sintomas: 18/10/2026")
    expect(text).to include("13 Raça/Cor: 4 — Parda", "6 Unidade de saúde (notificadora): UBS Vigia — CNES 2345678")
    expect(text).to include("11 Sexo: F — Feminino", "16 Nome da mãe: Joana da Silva")
  end

  it "UF e município vêm do perfil da cidade; residente fora mostra só o IBGE informado" do
    CityProfile.create!(name: "Curitiba", uf: "PR", ibge_code: "4106902")
    text = text_of(described_class.call(notification))
    expect(text).to include("4 UF: PR", "5 Município de notificação: Curitiba — IBGE 4106902", "18 Município de residência: Curitiba — IBGE 4106902")

    elsewhere = notification!(patient: surveillance_patient!(2), unit: unit, by: doctor, suspected_at: suspected_at, resident_elsewhere: true,
                              residence_ibge: "3550308")
    expect(text_of(described_class.call(elsewhere))).to include("18 Município de residência: IBGE 3550308")
  end

  it "calcula a idade na data da notificação, não na de hoje" do
    patient.update!(birth_date: "2000-10-21")
    expect(text_of(described_class.call(notification))).to include("10 Idade (na data da notificação): 25 anos")
    patient.update!(birth_date: "2000-10-20")
    expect(text_of(described_class.call(notification.reload))).to include("10 Idade (na data da notificação): 26 anos")
  end

  it "o notificador sai com o nome profissional e a função, nunca o e-mail" do
    text = text_of(described_class.call(notification))

    expect(text).to include("Notificador", doctor.professional.professional_name)
    expect(text).to include("Função: 225125")
    expect(text).not_to include(doctor.email_address)
  end

  it "sem perfil profissional o notificador é 'não informado' (nunca o e-mail)" do
    n = notification!(patient: patient, unit: unit, suspected_at: suspected_at) # by: vigilante sem Professional
    text = text_of(described_class.call(n))

    expect(text).to include("Nome: não informado")
    expect(text).not_to include(n.notifier_user.email_address)
  end

  it "paciente sem CPF mostra o CNS; o CPF nunca sai" do
    cns = valid_cns(7)
    nameless = Patient.create!(full_name: "Lia Santos", birth_date: "1990-05-01", sex: "female", no_cpf_reason: "3", cns: cns)
    n = notification!(patient: nameless, unit: unit, by: doctor, suspected_at: suspected_at)
    text = text_of(described_class.call(n))

    expect(text).to include("15 Nº do Cartão SUS: #{cns}")
    expect(text_of(described_class.call(notification))).not_to include(patient.cpf)
  end

  it "sem raça/cor na ficha usa a do paciente; sem nenhuma, 9 — Ignorado" do
    notification.update!(form: {})
    expect(text_of(described_class.call(notification))).to include("13 Raça/Cor: 4 — Parda")
    patient.update!(race_color: nil)
    expect(text_of(described_class.call(notification.reload))).to include("13 Raça/Cor: 9 — Ignorado")
  end

  it "a ficha de código sai com a descrição e o endereço formatado" do
    notification.update!(form: { "race_color" => "3", "schooling" => "6", "residence_zip" => "80010000", "phone" => "41999998888",
                                 "residence_zone" => "1", "occupation_cbo" => "225125" })
    text = text_of(described_class.call(notification))

    expect(text).to include("13 Raça/Cor: 3 — Amarela", "14 Escolaridade: 6 — Ensino médio completo")
    expect(text).to include("27 CEP: 80010-000", "28 (DDD) Telefone: (41) 99999-8888", "29 Zona: 1 — Urbana", "Ocupação (CBO): 225125")
  end

  it "rodapé e 'Página n de N' em toda página" do
    pages = reader(described_class.call(notification)).pages
    text = pages.map(&:text).join(" ").gsub(/\s+/, " ")

    expect(pages.size).to eq(1)
    expect(text).to include("Gerado pelo Rota Saúde — não substitui o registro no Sinan", "Página 1 de 1")
  end

  it "nome de 70 caracteres, com ou sem espaços, não estoura a página (1 página)" do
    [ "Maria Aparecida dos Santos Albuquerque Cavalcanti de Souza Pereira Lima Jr", "A" * 70 ].each do |name|
      patient.update!(full_name: name)
      pages = reader(described_class.call(notification.reload)).pages

      expect(pages.size).to eq(1)
      expect(pages.map(&:text).join.delete(" \n")).to include(name.delete(" ")[0, 70])
    end
  end

  it "a situação da notificação sai em português; a descartada avisa para não digitar no Sinan" do
    text = text_of(described_class.call(notification))
    expect(text).to include("Situação", "Notificada")

    dismissed = panel_case!(neighborhood: nil, symptoms_on: Date.new(2026, 10, 18), suspected_on: Date.new(2026, 10, 20), status: "dismissed")
    expect(text_of(described_class.call(dismissed))).to include("Situação", "Descartada pela vigilância", "NÃO digitar no Sinan")
  end
end
