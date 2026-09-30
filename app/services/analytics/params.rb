module Analytics
  # Parâmetros de GET /admin/api/analytics/:front (contratos §1; desvio 5 do
  # plano). Recusa com o código do contrato (Invalid#code). Recorte que não
  # vale para a frente é ignorado e volta nulo em `filter`.
  class Params
    class Invalid < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    FRONTS = %w[demand quality calibration epidemiology].freeze
    GRANULARITIES = %w[week month].freeze
    MAX_PERIODS = { "week" => 104, "month" => 60 }.freeze
    FILTERS = {
      "demand" => %i[neighborhood unit protocol],
      "quality" => %i[unit],
      "calibration" => %i[protocol version],
      "epidemiology" => %i[neighborhood protocol version]
    }.freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    NONE = "none"

    attr_reader :front, :from, :to, :granularity, :neighborhood_id, :health_unit_id, :protocol_name, :protocol_version

    def initialize(front, raw, today: Time.zone.today)
      @front = front
      allowed = FILTERS.fetch(front)
      @from = date(raw[:from])
      @to = [ date(raw[:to]), today - 1 ].min
      raise Invalid, "invalid_range" if @from > @to

      @granularity = front == "calibration" ? nil : granularity_from(raw[:granularity])
      raise Invalid, "invalid_range" if period_count > MAX_PERIODS.fetch(@granularity || "month")

      @neighborhood_id = neighborhood(raw[:neighborhood_id]) if allowed.include?(:neighborhood)
      @health_unit_id = unit(raw[:health_unit_id]) if allowed.include?(:unit)
      @protocol_name = protocol(raw[:protocol_name]) if allowed.include?(:protocol)
      @protocol_version = version(raw[:protocol_version]) if allowed.include?(:version)
    end

    # Início de cada período, do período do `from` ao do `to` (contratos §0).
    def periods
      return [] if @granularity.nil?

      list = []
      cursor = period_start(@from)
      while cursor <= @to
        list << cursor
        cursor = @granularity == "week" ? cursor + 7 : cursor.next_month
      end
      list
    end

    def period_sql = "date_trunc('#{@granularity}', day)::date"

    def neighborhood? = !@neighborhood_id.nil?

    def neighborhood_value = @neighborhood_id == NONE ? nil : @neighborhood_id

    def filter
      { neighborhood_id: @neighborhood_id, health_unit_id: @health_unit_id, protocol_name: @protocol_name,
        protocol_version: @protocol_version }
    end

    private

    def period_start(date) = @granularity == "month" ? date.beginning_of_month : date.beginning_of_week

    def period_count
      if @granularity == "week"
        ((@to.beginning_of_week - @from.beginning_of_week).to_i / 7) + 1
      else
        (@to.year * 12 + @to.month) - (@from.year * 12 + @from.month) + 1
      end
    end

    def date(value)
      raise Invalid, "invalid_range" unless value.is_a?(String) && value.match?(DATE)

      Date.strptime(value, "%Y-%m-%d")
    rescue Date::Error
      raise Invalid, "invalid_range"
    end

    def granularity_from(value)
      return "week" if value.nil? || value == ""
      raise Invalid, "invalid_range" unless GRANULARITIES.include?(value)

      value
    end

    def neighborhood(value)
      return nil if value.nil? || value == ""
      raise Invalid, "invalid_neighborhood" unless value.is_a?(String)
      return NONE if value == NONE
      raise Invalid, "invalid_neighborhood" unless value.match?(UUID) && Neighborhood.exists?(id: value)

      value
    end

    def unit(value)
      return nil if value.nil? || value == ""
      raise Invalid, "invalid_unit" unless value.is_a?(String) && value.match?(UUID) && HealthUnit.exists?(id: value)

      value
    end

    def protocol(value)
      return nil if value.nil? || value == ""
      raise Invalid, "invalid_protocol" unless value.is_a?(String) && ProtocolDefinition.exists?(name: value)

      value
    end

    def version(value)
      return nil if value.nil? || value == ""
      raise Invalid, "invalid_protocol" unless @protocol_name && value.is_a?(String) && value.match?(/\A\d{1,9}\z/)
      raise Invalid, "invalid_protocol" unless ProtocolDefinition.exists?(name: @protocol_name, version: value.to_i)

      value.to_i
    end
  end
end
