# Contagem da fila LEDI de uma cidade numa competência (desvio 7 do plano do
# exportador). Escrita só por Ledi::PublishProductionJob; lida pelo console.
class CityProductionSummary < PlatformRecord
  belongs_to :city
end
