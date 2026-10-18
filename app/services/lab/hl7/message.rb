# Leitura de uma mensagem HL7 v2 ER7 (perfil rotasaude.lab.hl7.v1): só os
# delimitadores padrão; segmentos separados por \r (aceita \n e \r\n);
# UTF-8. Nada da mensagem vai a log ou exceção: Invalid leva só o código.
module Lab
  module Hl7
    class Invalid < StandardError
      attr_reader :code

      def initialize(code = "invalid_message")
        @code = code
        super(code)
      end
    end

    Obx = Data.define(:segment, :index)
    Order = Data.define(:obr, :index, :results)
    Specimen = Data.define(:spm, :index, :orders)

    class Message
      DELIMITERS = "|^~\\&".freeze
      CONTROL = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
      SEGMENT = /\A[A-Z][A-Z0-9]{2}\|/
      UNESCAPE = { "\\F\\" => "|", "\\S\\" => "^", "\\T\\" => "&", "\\R\\" => "~", "\\E\\" => "\\" }.freeze

      attr_reader :segments

      def self.parse(raw)
        text = raw.to_s.dup.force_encoding(Encoding::UTF_8)
        raise Invalid unless text.valid_encoding?

        lines = text.split(/\r\n|\r|\n/).reject(&:empty?)
        raise Invalid unless lines.first&.start_with?("MSH") && lines.first[3, 5] == DELIMITERS
        raise Invalid unless lines.all? { |line| line.match?(SEGMENT) }
        # Uma mensagem por corpo; sem NUL/controles (o banco recusaria com 500).
        raise Invalid if text.match?(CONTROL) || lines.drop(1).any? { |line| line.start_with?("MSH|", "FHS|", "BHS|", "BTS|", "FTS|") }

        new(lines.map { |line| line.split("|", -1) })
      end

      def self.unescape(text) = text.gsub(/\\[FSTRE]\\/) { |seq| UNESCAPE.fetch(seq) }

      def initialize(segments)
        @segments = segments
      end

      # MSH-n: o campo 1 é o próprio separador, então MSH-n = posição n - 1.
      def msh(n, component = nil) = pick(segments.first[n - 1], component)
      def type = [ msh(9, 1), msh(9, 2), msh(9, 3) ].join("^")
      def control_id = msh(10, 1).to_s
      def version = msh(12, 1).to_s
      # Tabela 0103: só P, D, T; o perfil só usa P, que é o padrão para o resto.
      def processing_id = %w[P D T].include?(msh(11, 1)) ? msh(11, 1) : "P"
      # Campo do MSH como veio (HD com componentes); já passou pelo split por "|".
      def raw_msh(n) = segments.first[n - 1].to_s
      def inspect = "#<Lab::Hl7::Message type=#{type} segments=#{segments.size}>"
      def first(name) = segments.find { |s| s.first == name }
      def field(segment, n, component = nil) = segment && pick(segment[n], component)

      # Código de barras do SPM: SPM-2.1, ou SPM-2.2 se o primeiro vier vazio.
      def barcode(specimen) = field(specimen.spm, 2, 1).presence || field(specimen.spm, 2, 2).to_s

      # SPM-11 (Specimen Role, tabela 0369): "Q" = controle (Task 0).
      def specimen_role(specimen) = field(specimen.spm, 11, 1).to_s

      # Componente 1 de cada repetição do campo (OBX-18 é repetível; Task 0).
      def repetitions(segment, n)
        return [] unless segment

        segment[n].to_s.split("~", -1).map { |rep| self.class.unescape(rep.split("^", -1).first.to_s) }.reject(&:empty?)
      end

      # Grupos do OUL^R22: SPM → OBR → OBX (OBX antes do 1º OBR é da amostra e é ignorado).
      def specimens
        counts = Hash.new(0)
        groups = []
        segments.each do |segment|
          name = segment.first
          counts[name] += 1
          case name
          when "SPM" then groups << Specimen.new(spm: segment, index: counts[name], orders: [])
          when "OBR" then groups.last&.orders&.push(Order.new(obr: segment, index: counts[name], results: []))
          when "OBX" then groups.last&.orders&.last&.results&.push(Obx.new(segment: segment, index: counts[name]))
          end
        end
        groups
      end

      # Problemas de forma do OUL^R22, TODOS (B26): um Builder::Error por recusa, na ordem
      # dos segmentos. Só a forma; o que depende do banco (faixa, unidade) é da Inbound.
      def structure_errors
        orphans + specimens.flat_map do |specimen|
          found = []
          found << refusal("unknown_barcode", "SPM", specimen.index, 2) if barcode(specimen).blank?
          specimen.orders.each do |order|
            found << refusal("exam_not_in_version", "OBR", order.index, 4) if field(order.obr, 4, 1).blank?
            order.results.each do |obx|
              found << refusal("unknown_analyte", "OBX", obx.index, 3) if field(obx.segment, 3, 1).blank?
              found << refusal("invalid_value", "OBX", obx.index, 5) if field(obx.segment, 5, 1).blank?
            end
          end
          found
        end
      end

      private

      # OBR/OBX antes do 1º SPM: nada numa mensagem é ignorado em silêncio (B26).
      def orphans
        counts = Hash.new(0)
        found = []
        segments.each do |segment|
          name = segment.first
          counts[name] += 1
          break if name == "SPM"

          found << refusal("invalid_message", name, counts[name], 1) if %w[OBR OBX].include?(name)
        end
        found
      end

      def refusal(code, segment, index, field) = Builder::Error.new(code: code, location: "#{segment}^#{index}^#{field}")

      # Primeira repetição; componente 1-based; sem componente, o campo inteiro.
      def pick(value, component)
        first = value.to_s.split("~", -1).first.to_s
        raw = component ? first.split("^", -1)[component - 1].to_s : first
        self.class.unescape(raw)
      end
    end
  end
end
