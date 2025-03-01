////////////////////////////////////////////////////////////////////////////////
// Utilities
////////////////////////////////////////////////////////////////////////////////
var<private> rand_seed : vec2<f32>;
const albedo = vec3<f32>(0.9,0.7,0.4);
const PI:f32=3.1416926535928;
struct SimulationCS {
    MeasurementAltitude: f32,
    TSnowA:f32,
    TSnowB:f32,
    TMeltA:f32,
    TMeltB:f32,
    k_e:f32,
    k_m:f32,
    meltFactor:f32,
};
const SimulationCSConstants: SimulationCS = SimulationCS(0.0,0.0,2.0,-5.0,-2.0,0.2,4.0, 2.0);

struct ConfigurationCS {
  posNormalizeFactor: f32,
  posMax: f32,
  colorMaxScaleFactor: f32,
  areaScaleFactor: f32,
  r_i_tScaleFactor: f32,
  maxSWE: f32,
  temperatureLapseNormalizeFactor: f32,
  precipitationLapseNormalizeFactor: f32,
};

struct WeatherData
{
	Temperature:f32,
	Precipitation:f32,
};

struct SimulationCSVar {
    Timesteps: f32,
    CurrentSimulationStep: f32,
    HourOfDay: f32,
    DayOfYear: f32,
};

const SimulationCSVariables: SimulationCSVar = SimulationCSVar(0,0,12,35);

fn init_rand(invocation_id : u32, seed : vec4<f32>) {
  rand_seed = seed.xz;
  rand_seed = fract(rand_seed * cos(35.456+f32(invocation_id) * seed.yw));
  rand_seed = fract(rand_seed * cos(41.235+f32(invocation_id) * seed.xw));
}

fn rand() -> f32 {
  rand_seed.x = fract(cos(dot(rand_seed, vec2<f32>(23.14077926, 232.61690225))) * 136.8168);
  rand_seed.y = fract(cos(dot(rand_seed, vec2<f32>(54.47856553, 345.84153136))) * 534.7645);
  return rand_seed.y;
}

fn Func2(L: f32, D: f32) -> f32 {
    return acos(clamp(-tan(L) * tan(D), -1.0, 1.0));
}

fn Func3(V: f32, W: f32, X: f32, Y: f32, R1: f32, D: f32) -> f32 {
    return R1 * (sin(D) * sin(W) * (X - Y) * (12.0 / PI) +
                 cos(D) * cos(W) * (sin(X + V) - sin(Y + V)) * (12.0 / PI));
}

fn SolarRadiationIndex(I: f32, A: f32, L0: f32, J: f32) -> vec3<f32>{
    var L1: f32 = acos(cos(I) * sin(L0) + sin(I) * cos(L0) * cos(A));
    var D1: f32 = cos(I) * cos(L0) - sin(I) * sin(L0) * cos(A);
    var L2: f32 = atan(sin(I) * sin(A) / (cos(I) * cos(L0) - sin(I) * sin(L0) * cos(A)));

    var D: f32 = 0.007 - 0.4067 * cos((J + 10.0) * 0.0172);
    var E: f32 = 1.0 - 0.0167 * cos((J - 3.0) * 0.0172);

    let R0: f32 = 1.95;
    var R1: f32 = 60.0 * R0 / (E * E);

    var T: f32;
    T = Func2(L1, D);
    var T7: f32 = T - L2;
    var T6: f32 = -T - L2;
    T = Func2(L0, D);
    var T1: f32 = T;
    var T0: f32 = -T;
    var T3: f32 = min(T7, T1);
    var T2: f32 = max(T6, T0);

    var T4: f32 = T2 * (12.0 / PI);
    var T5: f32 = T3 * (12.0 / PI);

    if (T3 < T2) {
        T2 = 0.0;
        T3 = 0.0;
    }

    T6 = T6 + PI * 2.0;

    var R4: f32;
    if (T6 < T1) {
        var T8: f32 = T6;
        var T9: f32 = T1;
        R4 = Func3(L2, L1, T3, T2, R1, D) + Func3(L2, L1, T9, T8, R1, D);
    } else {
        T7 = T7 - PI * 2.0;

        if (T7 > T0) {
            var T8: f32 = T0;
            var T9: f32 = T0;
            R4 = Func3(L2, L1, T3, T2, R1, D) + Func3(L2, L1, T9, T8, R1, D);
        } else {
            R4 = Func3(L2, L1, T3, T2, R1, D);
        }
    }

    var R3: f32 = Func3(0.0, L0, T1, T0, R1, D);

    return vec3<f32>(T4,T5,R4 / R3);
}

////////////////////////////////////////////////////////////////////////////////
// Vertex shader
////////////////////////////////////////////////////////////////////////////////
struct RenderParams {
  modelViewProjectionMatrix : mat4x4<f32>,
  campos : vec3<f32>,
  fogStart:f32,
  up : vec2<f32>,
  fogEnd:f32,
  heightMul : f32,
  configurationCSVariables: ConfigurationCS,
}
@binding(0) @group(0) var<uniform> render_params : RenderParams;
@binding(1) @group(0) var fragtexture : texture_2d<f32>;
@binding(2) @group(0) var origtexture : texture_2d<f32>;
@binding(3) @group(0) var<uniform>  grid : vec2<f32>;
@binding(4) @group(0) var heighttexture : texture_2d<f32>;
@binding(5) @group(0) var<storage, read> maxSnow : array<u32>; // TODO: BINDING NUMBER

struct VertexInput {
  @location(0) position : vec3<f32>,
  @location(1) normal : f32,
  @location(2) uv: vec2<f32>, // -1..+1
}

struct VertexOutput {
  @location(0) position: vec3<f32>,
  @location(1) normal : vec3<f32>,
  @location(2) uv : vec2<f32>, // -1..+1

  @builtin(position) Position : vec4<f32>,
}
const heightMul:f32=0.01;
@vertex
fn vs_main(in : VertexInput,
            @builtin(instance_index) instance: u32) -> VertexOutput {
  //var quad_pos = mat2x3<f32>(render_params.right, render_params.up) * in.quad_pos;
  //var position = in.position;

  // var in_position_height_offset = vec3<f32>(in.position.x, in.position.y + testColorMax.x, in.position.z);

  var out : VertexOutput;
  
  var textDim=vec2<i32>(textureDimensions(heighttexture));
  //textDim=vec2<i32>(5,5);
  let i = i32(instance);
  let cell = vec2<i32>(i % (textDim.x - 1), i / (textDim.x - 1)); // should one be textDim.y - 1?
  let p0:vec3<f32>=vec3<f32>(0.0,textureLoad(heighttexture,cell,0).x*render_params.heightMul,0.0);
  let p1:vec3<f32>=vec3<f32>(grid.x,textureLoad(heighttexture,vec2<i32>(cell.x+1,cell.y),0).x*render_params.heightMul,0.0);
  let p2:vec3<f32>=vec3<f32>(0.0,textureLoad(heighttexture,vec2<i32>(cell.x,cell.y+1),0).x*render_params.heightMul,grid.y);
  let p3:vec3<f32>=vec3<f32>(grid.x,textureLoad(heighttexture,vec2<i32>(cell.x+1,cell.y+1),0).x*render_params.heightMul,grid.y);
  /*let p0:vec3<f32>=vec3<f32>(0.0,0.0,0.0);
  let p1:vec3<f32>=vec3<f32>(grid.x,30.0,0.0);
  let p2:vec3<f32>=vec3<f32>(0.0,30.0,grid.y);
  let p3:vec3<f32>=vec3<f32>(grid.x,90.0,grid.y);*/
  var normal:vec3<f32>;
  if(in.normal==0.0){
    normal=normalize(cross(p2-p0,p3-p0));
  }else{
    normal=normalize(cross(p3-p0,p1-p0));
  }
  var coord:vec2<i32>=cell;
  if(in.position.x > 0.0){
    coord.x+=1;
  }
  if(in.position.z > 0.0){
    coord.y+=1;
  }
  //let cell = vec2<i32>(i % 2, i / 2);

  // Calculate displacement from snow
  var fragDim=vec2<i32>(textureDimensions(fragtexture).xy);
  var fragCoord : vec2<i32>=vec2<i32>(0,0);
  fragCoord.x=i32(f32(coord.x) / f32(textDim.x) * f32(fragDim.x)); 
  fragCoord.y=i32(f32(coord.y) / f32(textDim.y) * f32(fragDim.y));  

  var testcolor = textureLoad(fragtexture, fragCoord.xy, 0); 
  var testColorFirst = testcolor / render_params.configurationCSVariables.posNormalizeFactor;
  var testColorMax = clamp(testColorFirst * render_params.configurationCSVariables.posMax * 10.0, vec4(0.0), vec4(render_params.configurationCSVariables.posMax)); // change these values so that they can be multiplied by render_params.heightMul
  let cellOffset = vec2<f32>(cell-textDim/2)*grid;
  var gridPos:vec2<f32> = (in.position.xz) * (grid/2.0) + cellOffset;
  
  var height:f32=textureLoad(heighttexture,coord,0).x;
  out.Position = render_params.modelViewProjectionMatrix * vec4<f32>(gridPos.x,(height + testColorMax.x)*render_params.heightMul,gridPos.y, 1.0);
  out.position=vec3<f32>(gridPos.x,(height + testColorMax.x)*render_params.heightMul,gridPos.y);
  out.normal =normal;
  out.uv = vec2<f32>(f32(coord.x)/f32(textDim.x),f32(coord.y)/f32(textDim.y));
  return out;
}

////////////////////////////////////////////////////////////////////////////////
// Fragment shader
////////////////////////////////////////////////////////////////////////////////

const lightPos : vec3<f32>= vec3<f32> (50.0, 100.0, -100.0);
const lightDir : vec3<f32>= vec3<f32> (1.0, -1.0, 0.0);
const ambientFactor = 0.4;
/*
CRYSTAL: There are two texture bind to fragment shader
fragtexture: the texture buffer that got from compute pipeline
origtexture: the texture buffer that is the original texture

They varies in resolution, better to interpolate values for final result, but rn, change between these two to test whether we have correct computation.
*/
const fogColor:vec3<f32> =vec3<f32>(0.5,0.5,0.5);

@fragment
fn fs_main(in : VertexOutput) -> @location(0) vec4<f32> {
  var test=render_params.modelViewProjectionMatrix;
  var textDim=vec2<i32>(textureDimensions(fragtexture).xy);
  var textorigDim=vec2<i32>(textureDimensions(origtexture).xy);
  var coord : vec2<i32>=vec2<i32>(0,0);

  //CRYSTAL: change following three lines of code for testing different textures
  coord.x=i32(f32(textDim.x)*in.uv.x);
  coord.y=i32(f32(textDim.y)*in.uv.y);
  var testcolor = textureLoad(fragtexture, coord.xy, 0);

  coord.x=i32(f32(textorigDim.x)*in.uv.x);
  coord.y=i32(f32(textorigDim.y)*in.uv.y);
  var origcolor = textureLoad(origtexture, coord.xy, 0);

  // this should be maxSnow[0] instead of maxSnow[0] * 0.4, but leaving it here until debugged
  // var testColorMaxFirst = clamp(testcolor / (f32(maxSnow[0]) * 0.35), vec4(0.0), vec4(1.0));
  var testColorMaxFirst = testcolor / (f32(maxSnow[0]) * render_params.configurationCSVariables.colorMaxScaleFactor);
  var testColorMaxScaled = select(testColorMaxFirst * 1.75, testColorMaxFirst * 0.75 + 0.20, testColorMaxFirst.x > 0.2); 
  var testcolorMax = clamp(testColorMaxScaled, vec4(0.0), vec4(1.0));
  // var out_color = testcolorMax;
  // var out_color = testcolor;
  var out_color = (1.0-testcolorMax.x)*origcolor+testcolorMax.x*testcolorMax;
  // var out_color = vec4(maxSnow[0]);

  let lambertFactor = max(dot(normalize(-lightDir), in.normal), 0.0);
  let lightingFactor = min(ambientFactor + lambertFactor, 1.0);
  var color = vec4(lightingFactor*out_color.xyz,1.0);
  var fogStart:f32 =render_params.fogStart;
  var fogEnd:f32 =render_params.fogEnd;
  let fogFactor:f32= clamp((fogEnd-length(render_params.campos-in.position))/(fogEnd-fogStart),0.0,1.0);
  let fogColorVec4: vec4<f32> =vec4<f32>(fogColor,1.0);
  let colorWithFog:vec4<f32>=mix(fogColorVec4,color,fogFactor);
  // var color = vec4(out_color.xyz,1.0);
  // Apply a circular particle alpha mask
  //color.a = color.a * max(1.0 - length(in.quad_pos), 0.0);
  return colorWithFog;
}

////////////////////////////////////////////////////////////////////////////////
// Simulation Compute shader
////////////////////////////////////////////////////////////////////////////////

struct SimulationParams {
  simulationCSConstants: SimulationCS,
  simulationCSVariables: SimulationCSVar,
  configurationCSVariables: ConfigurationCS,
  temperature: f32,
  precipitation: f32,
}

struct Particle {
  position : vec3<f32>,
  lifetime : f32,
  color    : vec4<f32>,
  velocity : vec3<f32>,
}
struct Particles {
  particles : array<Particle>,
}

struct Cell { 
  Aspect: f32,
  Inclination: f32,
  Altitude: f32,
  Latitude: f32,
  Area: f32,
  AreaXY: f32,
  SnowWaterEquivalent: f32,
  InterpolatedSWE: f32,
  SnowAlbedo: f32,
  DaysSinceLastSnowfall: f32,
  Curvature: f32,
  Padding:f32,
}
struct Cells {
  cells : array<Cell>,
}

@binding(0) @group(0) var<uniform> simParams : SimulationParams;
@binding(1) @group(0) var<storage, read_write> data : Cells;
@binding(2) @group(0) var texture : texture_2d<f32>;
@binding(3) @group(0) var texture2 : texture_storage_2d<rgba32float, write>;
@binding(4) @group(0) var<storage, read_write> maxSnowStorage : array<atomic<u32>>;

@compute @workgroup_size(8,8)
fn simulate(@builtin(global_invocation_id) global_invocation_id : vec3<u32>) {
    
    var textDim=vec2<i32>(textureDimensions(texture).xy);
    var text2Dim=vec2<i32>(textureDimensions(texture2).xy);
    var coord : vec2<i32>=vec2<i32>(global_invocation_id.xy);
    var idx: u32= global_invocation_id.y*textureDimensions(texture2).x+global_invocation_id.x;
    //var idx: u32= global_invocation_id.x;

    // init_rand(idx, simParams.seed);
    var loadcoord : vec2<i32>=vec2<i32>(0,0);
    loadcoord.x=i32(coord.x*textDim.x/text2Dim.x);
    loadcoord.y=i32(coord.y*textDim.y/text2Dim.y);
    //CRYSTAL: color from original texture
    var color = textureLoad(texture, loadcoord, 0);
    
    //CRYSTAL: here is example of how to store color to texture, just modify color.xyz to change color
    // if (coord)
    // textureStore(texture2, vec2<i32>(coord.xy), vec4<f32>(color.xyz,1.0));


    //CRYSTAL: starting from this part, use the same code from that unreal project
    var celldata = data.cells[idx];
    
    var areaSquareMeters:f32 = celldata.AreaXY * simParams.configurationCSVariables.areaScaleFactor; // m^2 
    // var areaSquareMetersPrecip:f32 = celldata.AreaXY / 1000; // m^2

    //for (var time:i32 = 0; time < SimulationCSVariables.Timesteps; time=time+1) {
    var stationAltitudeOffset:f32 = celldata.Altitude - simParams.simulationCSConstants.MeasurementAltitude;
    var temperatureLapse:f32 = - (0.5 * stationAltitudeOffset) / (simParams.configurationCSVariables.temperatureLapseNormalizeFactor);

    var tAir:f32= simParams.temperature + temperatureLapse; // degree Celsius
    // var tAir:f32= simParams.temperature;

    var precipitationLapse:f32= 10.0 / 24.0 * stationAltitudeOffset / (simParams.configurationCSVariables.precipitationLapseNormalizeFactor);
        // const precipitationLapse: number = 0;
    var precipitation:f32 = simParams.precipitation;

    celldata.DaysSinceLastSnowfall += 1.0 / 24.0;
    
    var output_color_debug = 0.1;

      // Apply precipitation
    if (precipitation > 0.0) {
        precipitation += precipitationLapse;
        celldata.DaysSinceLastSnowfall = 0.0;

        // New snow/rainfall
        //let rain: boolean = tAir > SimulationCSConstants.TSnowB;

        if (tAir > simParams.simulationCSConstants.TSnowB) {
            celldata.SnowAlbedo = 0.4; // New rain drops the albedo to 0.4
        } else {
            // Variable lapse rate as described in "A variable lapse rate snowline model for the Remarkables, Central Otago, New Zealand"
            var snowRate:f32= max(0.0, 1.0 - (tAir - simParams.simulationCSConstants.TSnowA) / (simParams.simulationCSConstants.TSnowB - simParams.simulationCSConstants.TSnowA));

            celldata.SnowWaterEquivalent += (precipitation * areaSquareMeters * snowRate); // l/m^2 * m^2 = l
            // celldata.SnowWaterEquivalent += (precipitation * snowRate); // l/m^2 * m^2 = l
            celldata.SnowAlbedo = 0.8; // New snow sets the albedo to 0.8
        }
    }
      
      // Apply melt
    if (celldata.SnowWaterEquivalent > 0.0) {
        if (celldata.DaysSinceLastSnowfall >= 0.0) {
            celldata.SnowAlbedo = 0.4 * (1.0 + exp(-simParams.simulationCSConstants.k_e * celldata.DaysSinceLastSnowfall));
        }

        // Temperature higher than melt threshold and cell contains snow
        if (tAir > simParams.simulationCSConstants.TMeltA) {
            var dayNormalization: f32 = 1.0 / 24.0; // day

            // Radiation Index
            var output: vec3<f32> = SolarRadiationIndex(celldata.Inclination,celldata.Aspect, celldata.Latitude, f32(simParams.simulationCSVariables.DayOfYear)); // 1

            var r_i:f32=output.z;
            var T4: f32=output.x;
            var T5: f32=output.y;

            // Diurnal approximation
            var t: f32 = simParams.simulationCSVariables.HourOfDay;
            var D: f32 = abs(T4) + abs(T5);
            var r_i_t: f32 = max(abs(PI * r_i / 2.0 * sin(PI * f32(t) / D - abs(T4) / PI)) * simParams.configurationCSVariables.r_i_tScaleFactor, 0.0);
            // Melt factor
            var vegetationDensity: f32 = 0.0;
            var k_v: f32 = exp(-4.0 * vegetationDensity); // 1
            var c_m: f32 = simParams.simulationCSConstants.k_m * k_v * r_i_t * (1.0 - celldata.SnowAlbedo) * dayNormalization * areaSquareMeters; // l/m^2/C�/day * day * m^2 = l/m^2 * 1/day * day * m^2 = l/C�
            var meltFactor: f32;
            if(tAir < simParams.simulationCSConstants.TMeltB){
              // do something with abs of difference between A
                meltFactor=simParams.simulationCSConstants.meltFactor * (tAir - simParams.simulationCSConstants.TMeltA + 0.01) * (tAir - simParams.simulationCSConstants.TMeltA + 0.01) / (simParams.simulationCSConstants.TMeltB - simParams.simulationCSConstants.TMeltA);
            } else {
                meltFactor=simParams.simulationCSConstants.meltFactor * (tAir - simParams.simulationCSConstants.TMeltA);
            }

            // Added factor to speed up melting
            var m: f32 = c_m * meltFactor; // l/C� * C� = l 
            output_color_debug = r_i ;
            // Apply melt
            celldata.SnowWaterEquivalent -= m;
        }
    }
    celldata.SnowWaterEquivalent = clamp(celldata.SnowWaterEquivalent, 0, simParams.configurationCSVariables.maxSWE * celldata.AreaXY);
    var slope = degrees(celldata.Inclination);
    // var f = select((slope - (celldata.Altitude * (simParams.configurationCSVariables.areaScaleFactor / 100.0)) / 100.0) / 65.0 , 0, slope < 15.0);
    var f = select(slope / 65.0 , 0, slope < 15.0);
	  var a3 = 50.0;

    // celldata.InterpolatedSWE = celldata.SnowWaterEquivalent * (1 - f);
    celldata.InterpolatedSWE = clamp(celldata.SnowWaterEquivalent * (1.1 - f) * (1 + a3 * celldata.Curvature), 0.0, simParams.configurationCSVariables.maxSWE * celldata.AreaXY);
    // celldata.InterpolatewdSWE = celldata.SnowWaterEquivalent;
    //celldata.Curvature-=0.001;
    data.cells[idx] = celldata;
    //var output_color: f32=celldata.SnowAlbedo;
    var output_color: f32=celldata.InterpolatedSWE;
    atomicMax(&maxSnowStorage[0],u32(output_color));
    var debug_color_y: f32 = f32(coord.y) / f32(textureDimensions(texture2).y);
    var debug_color_x: f32 = f32(coord.x) / f32(textureDimensions(texture2).x);
    
    textureStore(texture2, vec2<i32>(coord.xy), vec4<f32>(output_color,output_color,output_color,1.0));
    // textureStore(texture2, vec2<i32>(coord.xy), vec4<f32>(output_color_debug,output_color_debug,output_color_debug,1.0));

}