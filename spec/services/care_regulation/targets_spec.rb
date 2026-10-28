require "rails_helper"

# Módulo 26a (ADR 0044; contrato §13 G3, G11, G12 #6): alvos reguláveis.
RSpec.describe CareRegulation::Targets do
  before { regulation_city! }

  def resolve(type, code, **over) = described_class.resolve(type: type, code: code, **over)

  describe ".resolve" do
    it "especialidade: a linha do YAML, com o label como nome (G12 #6)" do
      target = resolve("specialty", "225120").payload.fetch(:target)
      expect(target).to have_attributes(type: "specialty", code: "225120", name: "Cardiologia", label: "Cardiologia", group: "medical")
      expect(target.to_json_hash).to eq(code: "225120", name: "Cardiologia")
      expect(resolve("specialty", "223212").payload.fetch(:target)).to have_attributes(name: "Endodontia", group: "dental")
    end

    it "especialidade fora da lista (excluída), formato ruim ou tipo desconhecido → invalid_target" do
      %w[225125 223260 abc 22512 2251200].each do |code|
        result = resolve("specialty", code)
        expect([ result.failure?, result.reason, result.details ]).to eq([ true, :invalid_target, { path: "target_code" } ])
      end
      expect(resolve("specialty", nil).reason).to eq(:invalid_target)
      expect(resolve("exam", "225120").reason).to eq(:invalid_target)
      expect(resolve(nil, "225120").reason).to eq(:invalid_target)
    end

    it "procedimento regulável: o nome da SIGTAP da competência" do
      target = resolve("procedure", "0301010072").payload.fetch(:target)
      expect(target).to have_attributes(type: "procedure", code: "0301010072", name: "CONSULTA MEDICA EM ATENÇÃO ESPECIALIZADA", group: "procedure")
      expect(target.label).to eq(target.name)
      expect(resolve("procedure", "0401010074")).to be_ok
    end

    it "G11: grupo 02–04 com BPA entra, mesmo com APAC principal; só APAC, grupo 01 ou só AIH não entram" do
      expect(resolve("procedure", "0209010037")).to be_ok # 02 04 06 07: BPA + APAC principal
      %w[0305010107 0101010010 0407030026 0409050083].each do |code|
        result = resolve("procedure", code)
        expect([ result.failure?, result.reason, result.details ]).to eq([ true, :invalid_target, { path: "target_code" } ])
      end
    end

    it "código inexistente na release ou malformado → invalid_target" do
      %w[0301019999 030101007 03010100722 abcdefghij].each { |code| expect(resolve("procedure", code).reason).to eq(:invalid_target) }
    end

    it "sem release ativa na competência → invalid_target" do
      expect(resolve("procedure", "0301010072", on: Date.new(1999, 1, 1)).reason).to eq(:invalid_target)
    end

    it "usa a release da competência de `on` (a última ativa até ela)" do
      expect(resolve("procedure", "0301010072", on: Date.new(2000, 1, 15))).to be_ok
    end

    it "G3: exame ativo no catálogo do 21a → invalid_target com hint exam_order; inativo segue a regra" do
      exam_catalog_item!(sigtap_code: "0209010037")
      result = resolve("procedure", "0209010037")
      expect([ result.reason, result.details ]).to eq([ :invalid_target, { path: "target_code", hint: "exam_order" } ])

      ExamCatalogItem.find_by!(sigtap_code: "0209010037").update!(active: false)
      expect(resolve("procedure", "0209010037")).to be_ok
    end

    it "G3: exame ativo fora da regra (sem BPA na SIGTAP) também vai para o pedido de exame" do
      exam_catalog_item!(sigtap_code: "0202010503")
      expect(resolve("procedure", "0202010503").details).to eq(path: "target_code", hint: "exam_order")
      ExamCatalogItem.find_by!(sigtap_code: "0202010503").update!(active: false)
      expect(resolve("procedure", "0202010503").details).to eq(path: "target_code")
    end
  end

  describe ".search" do
    it "especialidade sem q: todas, por nome" do
      found = described_class.search(type: "specialty", query: nil, limit: 100)
      expect(found.size).to eq(YAML.safe_load_file(Rails.root.join("config/regulation/specialties.yml")).fetch("specialties").size)
      names = found.map(&:name)
      expect(names).to eq(names.sort_by { |name| I18n.transliterate(name).downcase })
      expect(names).to include("Cardiologia", "Endodontia")
    end

    it "especialidade com q: pelo nome dobrado (sem acento, minúsculo) ou prefixo do código" do
      expect(described_class.search(type: "specialty", query: "CARDIO").map(&:code)).to include("225120")
      expect(described_class.search(type: "specialty", query: "psiquiatría").map(&:code)).to eq(%w[225133])
      expect(described_class.search(type: "specialty", query: "psiquiatria").map(&:code)).to eq(%w[225133])
      expect(described_class.search(type: "specialty", query: "xyz")).to be_empty
      expect(described_class.search(type: "specialty", query: "2232").map(&:group).uniq).to eq(%w[dental])
    end

    it "limit corta a lista" do
      expect(described_class.search(type: "specialty", query: nil, limit: 5).size).to eq(5)
    end

    it "procedimento traz só reguláveis, por nome sem acento" do
      codes = described_class.search(type: "procedure", query: "esofago").map(&:code)
      expect(codes).to include("0209010037")
      expect(codes).not_to include("0305010107")
      expect(described_class.search(type: "procedure", query: "hemodialise")).to be_empty
      expect(described_class.search(type: "procedure", query: "ATENCAO especializada").map(&:code)).to eq(%w[0301010072])
    end

    it "procedimento por prefixo do código; fora do grupo 02–04 ou sem BPA não aparece" do
      expect(described_class.search(type: "procedure", query: "0301").map(&:code)).to eq(%w[0301010072])
      expect(described_class.search(type: "procedure", query: "0305")).to be_empty
      expect(described_class.search(type: "procedure", query: "0101")).to be_empty
    end

    it "procedimento exige q com 3+ caracteres (senão vazio) e respeita o limit" do
      expect(described_class.search(type: "procedure", query: "es")).to be_empty
      expect(described_class.search(type: "procedure", query: nil)).to be_empty
      expect(described_class.search(type: "procedure", query: "0", limit: 20)).to be_empty
    end

    it "o corte do limit (e o padrão de 20) vale com mais reguláveis do que o limite" do
      on = Date.new(2027, 3, 15)
      regulation_bulk_sigtap!("202703", count: 25)
      all = described_class.search(type: "procedure", query: "regulavel de teste", on: on, limit: 100)
      expect(all.size).to eq(25)
      expect(all.map(&:name)).to eq(all.map(&:name).sort)

      expect(described_class.search(type: "procedure", query: "regulavel de teste", on: on).size).to eq(20)
      expect(described_class.search(type: "procedure", query: "regulavel de teste", on: on, limit: 1).map(&:name)).to eq([ all.first.name ])
      expect(described_class.search(type: "procedure", query: "04019", on: on, limit: 7).size).to eq(7)
    end

    it "tipo desconhecido → vazio" do
      expect(described_class.search(type: "exam", query: "cardio")).to eq([])
    end
  end

  describe ".name_for" do
    it "especialidade pelo label; procedimento pelo nome da SIGTAP, regulável ou não; ausente → nil" do
      expect(described_class.name_for(type: "specialty", code: "225120")).to eq("Cardiologia")
      expect(described_class.name_for(type: "procedure", code: "0305010107")).to eq("HEMODIÁLISE (MÁXIMO 3 SESSÕES POR SEMANA)")
      expect(described_class.name_for(type: "procedure", code: "0000000000")).to be_nil
      expect(described_class.name_for(type: "specialty", code: "225125")).to be_nil
      expect(described_class.name_for(type: "x", code: "1")).to be_nil
    end

    it "names_for resolve a release uma vez só para vários alvos" do
      expect(Terminology::Sigtap).to receive(:release_for).once.and_call_original
      names = described_class.names_for([ %w[procedure 0209010037], %w[procedure 0305010107], %w[specialty 225120], %w[procedure 0000000000] ])
      expect(names).to eq([ "procedure", "0209010037" ] => "ESOFAGOGASTRODUODENOSCOPIA",
                          [ "procedure", "0305010107" ] => "HEMODIÁLISE (MÁXIMO 3 SESSÕES POR SEMANA)",
                          [ "specialty", "225120" ] => "Cardiologia", [ "procedure", "0000000000" ] => nil)
    end
  end
end
