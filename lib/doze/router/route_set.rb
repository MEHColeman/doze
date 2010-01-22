class Doze::Router::RouteSet
  def initialize(&block)
    @routes = []
    @routes_by_name = {}
    instance_eval(&block) if block
  end

  def <<(route)
    @routes << route
    @routes_by_name[route.name] = route
  end

  def [](name)
    @routes_by_name[name]
  end

  def route(*p, &b)
    self << Doze::Router::Route.new(*p, &b)
  end

  def each(&b)
    @routes.each(&b)
  end

  def dup(&block)
    route_set = self.class.new
    @routes.each {|r| route_set << r}
    route_set.instance_eval(&block) if block
    route_set
  end
end