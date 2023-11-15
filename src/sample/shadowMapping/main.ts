import { mat4, vec3 } from 'wgpu-matrix';
import { makeSample, SampleInit } from '../../components/SampleLayout';

import { mesh } from '../../meshes/stanfordDragon';

import vertexShadowWGSL from './vertexShadow.wgsl';
import vertexWGSL from './vertex.wgsl';
import fragmentWGSL from './fragment.wgsl';
import { WASDCamera, cameraSourceInfo } from './camera';
import { createInputHandler, inputSourceInfo } from './input';

const shadowDepthTextureSize = 1024;

function setCamera(x: number = 0, y: number = 30, z: number = -80)
{
  const initialCameraPosition = vec3.create(x, y, z);
  const initialCameraTarget = vec3.create(0, 15, 0);
  return new WASDCamera({ position: initialCameraPosition, target: initialCameraTarget });
}

const init: SampleInit = async ({ canvas, pageState, gui }) => {
  if (!pageState.active) return;

  // The input handler
  const inputHandler = createInputHandler(window, canvas);

  // Camera initialization
  let camera = setCamera();

  const cameraParams = 
  {
    resetCamera() {
      camera = setCamera();
    }
  };

  gui.add(cameraParams, 'resetCamera').name("Reset Camera");

  // GUI folders seem to bug the view out, disabling for now - 
  // the view sometimes doesn't appear when using a folder instead of just adding to gui
  // const camFolder = gui.addFolder("Camera");
  // camFolder.open();
  // camFolder.add(cameraParams, 'resetCamera').name("Reset Camera");

  const adapter = await navigator.gpu.requestAdapter();
  const device = await adapter.requestDevice();

  const context = canvas.getContext('webgpu') as GPUCanvasContext;

  const devicePixelRatio = window.devicePixelRatio;
  canvas.width = canvas.clientWidth * devicePixelRatio;
  canvas.height = canvas.clientHeight * devicePixelRatio;
  const aspect = canvas.width / canvas.height;
  const presentationFormat = navigator.gpu.getPreferredCanvasFormat();
  context.configure({
    device,
    format: presentationFormat,
    alphaMode: 'premultiplied',
  });

  // Create the model vertex buffer.
  const vertexBuffer = device.createBuffer({
    label: "vertex buffer",
    size: mesh.positions.length * 3 * 2 * Float32Array.BYTES_PER_ELEMENT,
    usage: GPUBufferUsage.VERTEX,
    mappedAtCreation: true,
  });
  {
    const mapping = new Float32Array(vertexBuffer.getMappedRange());
    for (let i = 0; i < mesh.positions.length; ++i) {
      mapping.set(mesh.positions[i], 6 * i);
      mapping.set(mesh.normals[i], 6 * i + 3);
    }
    vertexBuffer.unmap();
  }

  // Create the model index buffer.
  const indexCount = mesh.triangles.length * 3;
  const indexBuffer = device.createBuffer({
    label: "index buffer",
    size: indexCount * Uint16Array.BYTES_PER_ELEMENT,
    usage: GPUBufferUsage.INDEX,
    mappedAtCreation: true,
  });
  {
    const mapping = new Uint16Array(indexBuffer.getMappedRange());
    for (let i = 0; i < mesh.triangles.length; ++i) {
      mapping.set(mesh.triangles[i], 3 * i);
    }
    indexBuffer.unmap();
  }

  // Create the depth texture for rendering/sampling the shadow map.
  const shadowDepthTexture = device.createTexture({
    size: [shadowDepthTextureSize, shadowDepthTextureSize, 1],
    usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
    format: 'depth32float',
  });
  const shadowDepthTextureView = shadowDepthTexture.createView();

  // Create some common descriptors used for both the shadow pipeline
  // and the color rendering pipeline.
  const vertexBuffers: Iterable<GPUVertexBufferLayout> = [
    {
      arrayStride: Float32Array.BYTES_PER_ELEMENT * 6,
      attributes: [
        {
          // position
          shaderLocation: 0,
          offset: 0,
          format: 'float32x3',
        },
        {
          // normal
          shaderLocation: 1,
          offset: Float32Array.BYTES_PER_ELEMENT * 3,
          format: 'float32x3',
        },
      ],
    },
  ];

  const primitive: GPUPrimitiveState = {
    topology: 'triangle-list',
    cullMode: 'back',
  };

  const uniformBufferBindGroupLayout = device.createBindGroupLayout({
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.VERTEX,
        buffer: {
          type: 'uniform',
        },
      },
    ],
  });

  const shadowPipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({
      bindGroupLayouts: [
        uniformBufferBindGroupLayout,
        uniformBufferBindGroupLayout,
      ],
    }),
    vertex: {
      module: device.createShaderModule({
        code: vertexShadowWGSL,
        label: "Shadow vertex shader",
  }),
      entryPoint: 'main',
      buffers: vertexBuffers,
    },
    depthStencil: {
      depthWriteEnabled: true,
      depthCompare: 'less',
      format: 'depth32float',
    },
    primitive,
    label: "Shadow shader pipeline",
  });

  // Create a bind group layout which holds the scene uniforms and
  // the texture+sampler for depth. We create it manually because the WebPU
  // implementation doesn't infer this from the shader (yet).
  const bglForRender = device.createBindGroupLayout({
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
        buffer: {
          type: 'uniform',
        },
      },
      {
        binding: 1,
        visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
        texture: {
          sampleType: 'depth',
        },
      },
      {
        binding: 2,
        visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
        sampler: {
          type: 'comparison',
        },
      },
    ],
  });

  const pipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({
      bindGroupLayouts: [bglForRender, uniformBufferBindGroupLayout],
    }),
    vertex: {
      module: device.createShaderModule({
        code: vertexWGSL,
        label: "Render pipeline vertex shader",
      }),
      entryPoint: 'main',
      buffers: vertexBuffers,
    },
    fragment: {
      module: device.createShaderModule({
        code: fragmentWGSL,
        label: "Render pipeline fragment shader",
      }),
      entryPoint: 'main',
      targets: [
        {
          format: presentationFormat,
        },
      ],
      constants: {
        shadowDepthTextureSize,
      },
    },
    depthStencil: {
      depthWriteEnabled: true,
      depthCompare: 'less',
      format: 'depth24plus-stencil8',
    },
    primitive,
    label: "Render pipeline",
  });

  const depthTexture = device.createTexture({
    size: [canvas.width, canvas.height],
    format: 'depth24plus-stencil8',
    usage: GPUTextureUsage.RENDER_ATTACHMENT,
  });

  const renderPassDescriptor: GPURenderPassDescriptor = {
    colorAttachments: [
      {
        // view is acquired and set in render loop.
        view: undefined,

        clearValue: { r: 0.5, g: 0.5, b: 0.5, a: 1.0 },
        loadOp: 'clear',
        storeOp: 'store',
      },
    ],
    depthStencilAttachment: {
      view: depthTexture.createView(),

      depthClearValue: 1.0,
      depthLoadOp: 'clear',
      depthStoreOp: 'store',
      stencilClearValue: 0,
      stencilLoadOp: 'clear',
      stencilStoreOp: 'store',
    },
  };

  const modelUniformBuffer = device.createBuffer({
    label: 'modelUniformBuffer',
    size: 4 * 16, // 4x4 matrix
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const sceneUniformBuffer = device.createBuffer({
    // Two 4x4 viewProj matrices,
    // one for the camera and one for the light.
    // Then a vec3 for the light position.
    // Rounded to the nearest multiple of 16.
    label: 'sceneUniformBuffer',
    size: 2 * 4 * 16 + 4 * 4,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const sceneBindGroupForShadow = device.createBindGroup({
    layout: uniformBufferBindGroupLayout,
    entries: [
      {
        binding: 0,
        resource: {
          buffer: sceneUniformBuffer,
        },
      },
    ],
  });

  const sceneBindGroupForRender = device.createBindGroup({
    layout: bglForRender,
    entries: [
      {
        binding: 0,
        resource: {
          buffer: sceneUniformBuffer,
        },
      },
      {
        binding: 1,
        resource: shadowDepthTextureView,
      },
      {
        binding: 2,
        resource: device.createSampler({
          compare: 'less',
        }),
      },
    ],
  });

  const modelBindGroup = device.createBindGroup({
    layout: uniformBufferBindGroupLayout,
    entries: [
      {
        binding: 0,
        resource: {
          buffer: modelUniformBuffer,
        },
      },
    ],
  });

  const upVector = vec3.fromValues(0, 1, 0);
  const origin = vec3.fromValues(0, 0, 0);

  const projectionMatrix = mat4.perspective(
    (2 * Math.PI) / 5,
    aspect,
    1,
    2000.0
  );

  const lightPosition = vec3.fromValues(50, 100, -100);
  const lightViewMatrix = mat4.lookAt(lightPosition, origin, upVector);
  const lightProjectionMatrix = mat4.create();
  {
    const left = -80;
    const right = 80;
    const bottom = -80;
    const top = 80;
    const near = -200;
    const far = 300;
    mat4.ortho(left, right, bottom, top, near, far, lightProjectionMatrix);
  }

  const lightViewProjMatrix = mat4.multiply(
    lightProjectionMatrix,
    lightViewMatrix
  );

  // Move the model so it's centered.
  const modelMatrix = mat4.translation([0, -45, 0]);

  // The camera/light aren't moving, so write them into buffers now.
  {
    const lightMatrixData = lightViewProjMatrix as Float32Array;
    device.queue.writeBuffer(
      sceneUniformBuffer,
      0,
      lightMatrixData.buffer,
      lightMatrixData.byteOffset,
      lightMatrixData.byteLength
    );

    // I don't think this does anything because we are writing into sceneUniformBuffer
    // during frame() anyways.. this breaks the camera so just leaving it out for now
    // const cameraMatrixData = getModelViewProjectionMatrix(100) as Float32Array;
    // device.queue.writeBuffer(
    //   sceneUniformBuffer,
    //   64,
    //   cameraMatrixData.buffer,
    //   cameraMatrixData.byteOffset,
    //   cameraMatrixData.byteLength
    // );

    const lightData = lightPosition as Float32Array;
    device.queue.writeBuffer(
      sceneUniformBuffer,
      128,
      lightData.buffer,
      lightData.byteOffset,
      lightData.byteLength
    );

    const modelData = modelMatrix as Float32Array;
    device.queue.writeBuffer(
      modelUniformBuffer,
      0,
      modelData.buffer,
      modelData.byteOffset,
      modelData.byteLength
    );
  }

  const modelViewProjectionMatrix = mat4.create();

  function getModelViewProjectionMatrix(deltaTime: number) {
    const viewMatrix = camera.update(deltaTime, inputHandler());
    mat4.multiply(projectionMatrix, viewMatrix, modelViewProjectionMatrix);
    return modelViewProjectionMatrix as Float32Array;
  }

  const shadowPassDescriptor: GPURenderPassDescriptor = {
    colorAttachments: [],
    depthStencilAttachment: {
      view: shadowDepthTextureView,
      depthClearValue: 1.0,
      depthLoadOp: 'clear',
      depthStoreOp: 'store',
    },
  };

  let lastFrameMS = Date.now();

  function frame() {
    const now = Date.now();
    const deltaTime = (now - lastFrameMS) / 1000;
    lastFrameMS = now;

    // Sample is no longer the active page.
    if (!pageState.active) return;

    const cameraViewProj = getModelViewProjectionMatrix(deltaTime);
    device.queue.writeBuffer(
      sceneUniformBuffer,
      64,
      cameraViewProj.buffer,
      cameraViewProj.byteOffset,
      cameraViewProj.byteLength
    );

    renderPassDescriptor.colorAttachments[0].view = context
      .getCurrentTexture()
      .createView();

    const commandEncoder = device.createCommandEncoder();
    {
      const shadowPass = commandEncoder.beginRenderPass(shadowPassDescriptor);
      shadowPass.setPipeline(shadowPipeline);
      shadowPass.setBindGroup(0, sceneBindGroupForShadow);
      shadowPass.setBindGroup(1, modelBindGroup);
      shadowPass.setVertexBuffer(0, vertexBuffer);
      shadowPass.setIndexBuffer(indexBuffer, 'uint16');
      shadowPass.drawIndexed(indexCount);

      shadowPass.end();
    }
    {
      const renderPass = commandEncoder.beginRenderPass(renderPassDescriptor);
      renderPass.setPipeline(pipeline);
      renderPass.setBindGroup(0, sceneBindGroupForRender);
      renderPass.setBindGroup(1, modelBindGroup);
      renderPass.setVertexBuffer(0, vertexBuffer);
      renderPass.setIndexBuffer(indexBuffer, 'uint16');
      renderPass.drawIndexed(indexCount);

      renderPass.end();
    }
    device.queue.submit([commandEncoder.finish()]);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
};



const ShadowMapping: () => JSX.Element = () =>
  makeSample({
    name: 'Shadow Mapping',
    description:
      'This example shows how to sample from a depth texture to render shadows.',
    gui: true,
    init,
    sources: [
      {
        name: __filename.substring(__dirname.length + 1),
        contents: __SOURCE__,
      },
      {
        name: './vertexShadow.wgsl',
        contents: vertexShadowWGSL,
        editable: true,
      },
      {
        name: './vertex.wgsl',
        contents: vertexWGSL,
        editable: true,
      },
      {
        name: './fragment.wgsl',
        contents: fragmentWGSL,
        editable: true,
      },
    ],
    filename: __filename,
  });

export default ShadowMapping;
