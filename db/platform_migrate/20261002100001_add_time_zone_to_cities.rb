# api#27: fuso da cidade. O dia, os prazos e as janelas seguem o fuso da
# cidade, não um fuso fixo. Só os 16 identificadores IANA do Brasil (4 fusos,
# UTC-2 a UTC-5); as cidades existentes ficam em America/Sao_Paulo, o fuso que
# o sistema já usava. A lista é a mesma de City::TIME_ZONES.
class AddTimeZoneToCities < ActiveRecord::Migration[8.1]
  TIME_ZONES = %w[
    America/Noronha
    America/Belem America/Fortaleza America/Recife America/Araguaina America/Maceio America/Bahia
    America/Sao_Paulo America/Santarem
    America/Campo_Grande America/Cuiaba America/Porto_Velho America/Boa_Vista America/Manaus
    America/Eirunepe America/Rio_Branco
  ].freeze

  def change
    add_column :cities, :time_zone, :string, null: false, default: "America/Sao_Paulo"
    add_check_constraint :cities, "time_zone IN (#{TIME_ZONES.map { |z| "'#{z}'" }.join(', ')})",
                         name: "ck_cities_time_zone"
  end
end
