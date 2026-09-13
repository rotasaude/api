# Wrapper de cidade para jobs. Todo job que toca dado de domínio inclui isto.
# Falha fechada: sem cidade, levanta — não vaza.
#
# O job carrega o SLUG, não o objeto: o payload viaja pela fila, que ainda vive
# no banco compartilhado até o Plano 5.
module CityScopedJob
  extend ActiveSupport::Concern

  class CityMissing < StandardError; end

  private

  def with_city(slug)
    raise CityMissing, "#{self.class.name}: slug nulo" if slug.blank?

    city = City.find_by(slug: slug)
    raise CityMissing, "#{self.class.name}: cidade #{slug} não existe" if city.nil?

    Current.city = city
    CityConnection.with(city) { yield }
  end
end
