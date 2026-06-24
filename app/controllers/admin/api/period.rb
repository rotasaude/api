# Período do escopo do painel. Janelas em America/Sao_Paulo (não UTC).
#
#   today  → 00:00 do dia local → agora; buckets por hora (24)
#   7d     → últimos 7 dias locais; buckets por dia (7)
#   30d    → últimos 30 dias locais; buckets por dia (30)
#   custom → from/to ISO; buckets por dia
class Admin::Api::Period
  KEYS = %w[today 7d 30d custom].freeze

  attr_reader :key, :from, :to, :tz, :bucket

  def self.parse(key:, from:, to:, tz:)
    key = (key.presence || "7d").to_s
    raise Admin::Api::InvalidScope, "period inválido" unless KEYS.include?(key) || (from.present? && to.present?)

    now = tz.now
    case key
    when "today"
      f = now.beginning_of_day
      t = now
      new(key: "today", from: f, to: t, tz: tz, bucket: :hour)
    when "7d"
      f = (now - 6.days).beginning_of_day
      new(key: "7d", from: f, to: now, tz: tz, bucket: :day)
    when "30d"
      f = (now - 29.days).beginning_of_day
      new(key: "30d", from: f, to: now, tz: tz, bucket: :day)
    when "custom"
      f, t = parse_custom(from, to, tz)
      new(key: "custom", from: f, to: t, tz: tz, bucket: :day)
    else
      f, t = parse_custom(from, to, tz)
      new(key: "custom", from: f, to: t, tz: tz, bucket: :day)
    end
  end

  def initialize(key:, from:, to:, tz:, bucket:)
    @key = key
    @from = from
    @to = to
    @tz = tz
    @bucket = bucket
  end

  def descriptor
    { key: @key, label: label, axis: @bucket == :hour ? "hora" : "dia" }
  end

  def label
    case @key
    when "today" then "Hoje"
    when "7d"    then "7 dias"
    when "30d"   then "30 dias"
    else "Custom"
    end
  end

  # Série numérica com a granularidade do bucket. `relation` é um
  # ActiveRecord::Relation já filtrada por escopo; `time_column` é a coluna
  # a ser agrupada. Retorna `Array<Integer>` no tamanho do período.
  #
  # Qualifica a coluna com o nome real da tabela do model para evitar
  # ambiguidade em queries com join (ex.: triages.created_at vs
  # conversations.created_at).
  def series(relation, time_column)
    qualified = "#{relation.klass.table_name}.#{time_column}"
    raw = relation
            .where("#{qualified} BETWEEN ? AND ?", @from, @to)
            .group(group_expr(qualified))
            .count
    fill_buckets(raw)
  end

  def buckets
    @buckets ||= begin
      step = (@bucket == :hour ? 1.hour : 1.day)
      n = (@bucket == :hour ? 24 : ((@to.to_date - @from.to_date).to_i + 1))
      Array.new(n) { |i| (@from + i * step).send(@bucket == :hour ? :beginning_of_hour : :beginning_of_day) }
    end
  end

  private

  def self.parse_custom(from, to, tz)
    f = tz.parse(from.to_s).beginning_of_day
    t = tz.parse(to.to_s).end_of_day
    raise Admin::Api::InvalidScope, "from > to" if f > t
    [ f, t ]
  rescue ArgumentError
    raise Admin::Api::InvalidScope, "datas inválidas"
  end

  def group_expr(col)
    # date_trunc respeita timezone se a coluna for timestamptz; o app já roda
    # em UTC e Postgres converte ao truncar. Para granularidade de hora usamos
    # 'hour'; caso contrário 'day'.
    Arel.sql("date_trunc('#{@bucket}', #{col} AT TIME ZONE '#{@tz.name}')")
  end

  def fill_buckets(grouped)
    buckets.map do |b|
      key = b.in_time_zone(@tz)
      key = (@bucket == :hour ? key.beginning_of_hour : key.beginning_of_day)
      # date_trunc devolve TimestampTZ; comparamos por valor convertido.
      pair = grouped.find { |k, _| k && k.in_time_zone(@tz) == key }
      (pair && pair[1]) || 0
    end
  end
end
