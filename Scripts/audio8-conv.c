#define ACCELERATE_NEW_LAPACK
#include <Accelerate/Accelerate.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include "onnxruntime_c_api.h"

typedef struct {
    const OrtApi *api;
    int64_t dilation;
    int64_t stride;
} ConvKernel;

static const char *op_name(const OrtCustomOp *op) { return "AccelerateConv"; }
static const char *op_provider(const OrtCustomOp *op) { return NULL; }
static size_t input_count(const OrtCustomOp *op) { return 3; }
static size_t output_count(const OrtCustomOp *op) { return 1; }
static ONNXTensorElementDataType value_type(const OrtCustomOp *op, size_t index) {
    return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
}
static OrtCustomOpInputOutputCharacteristic required(const OrtCustomOp *op, size_t index) {
    return INPUT_OUTPUT_REQUIRED;
}
static OrtMemType memory_type(const OrtCustomOp *op, size_t index) { return OrtMemTypeDefault; }
static int version(const OrtCustomOp *op) { return 1; }

static OrtStatus *create_kernel(const OrtCustomOp *op, const OrtApi *api,
                                const OrtKernelInfo *info, void **kernel) {
    int64_t dilation, stride;
    size_t size = 1;
    OrtStatus *status = api->KernelInfoGetAttributeArray_int64(info, "dilations", &dilation, &size);
    if (status) return status;
    if (size != 1 || dilation < 1 || dilation > 9)
        return api->CreateStatus(ORT_INVALID_ARGUMENT, "Unexpected Audio8 convolution dilation");
    size = 1;
    status = api->KernelInfoGetAttributeArray_int64(info, "strides", &stride, &size);
    if (status) return status;
    if (size != 1 || (stride != 1 && stride != 2 && stride != 4 && stride != 8))
        return api->CreateStatus(ORT_INVALID_ARGUMENT, "Unexpected Audio8 convolution stride");
    ConvKernel *state = malloc(sizeof(*state));
    if (!state) return api->CreateStatus(ORT_FAIL, "Could not allocate Audio8 convolution kernel");
    state->api = api;
    state->dilation = dilation;
    state->stride = stride;
    *kernel = state;
    return NULL;
}

static OrtStatus *dimensions(const OrtApi *api, const OrtValue *value, int64_t *dims, size_t rank) {
    OrtTensorTypeAndShapeInfo *shape;
    OrtStatus *status = api->GetTensorTypeAndShape(value, &shape);
    if (status) return status;
    size_t actual = 0;
    status = api->GetDimensionsCount(shape, &actual);
    if (!status && actual == rank) status = api->GetDimensions(shape, dims, rank);
    else if (!status) status = api->CreateStatus(ORT_INVALID_ARGUMENT, "Unexpected Audio8 convolution rank");
    api->ReleaseTensorTypeAndShapeInfo(shape);
    return status;
}

#define CHECK(call) do { OrtStatus *status = (call); if (status) return status; } while (0)

// The upsampler scatters a dense projection of each input point to neighboring
// output samples. Form the projection in blocks to keep the workspace bounded.
static OrtStatus *transpose_conv(const OrtApi *api, const float *input, const float *weights,
                                float *output, int batch, int channels, int width, int rows,
                                int taps, int stride, int output_width) {
    const int tile = width < 256 ? width : 256;
    const int projected_rows = rows * taps;
    float *projected = malloc((size_t)projected_rows * tile * sizeof(float));
    if (!projected) return api->CreateStatus(ORT_FAIL, "Could not allocate Audio8 upsampling workspace");
    for (int i = 0; i < batch; ++i) {
        const float *source = input + (size_t)i * channels * width;
        float *target = output + (size_t)i * rows * output_width;
        memset(target, 0, (size_t)rows * output_width * sizeof(float));
        for (int first = 0; first < width; first += tile) {
            const int span = width - first < tile ? width - first : tile;
            cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, projected_rows, span, channels,
                        1, weights, projected_rows, source + first, width, 0, projected, span);
            for (int row = 0; row < rows; ++row) {
                float *line = target + (size_t)row * output_width + first * stride;
                for (int tap = 0; tap < taps; ++tap) {
                    const float *values = projected + (size_t)(row * taps + tap) * span;
                    for (int sample = 0; sample < span; ++sample)
                        line[sample * stride + tap] += values[sample];
                }
            }
        }
    }
    free(projected);
    return NULL;
}

static OrtStatus *compute(void *state, OrtKernelContext *context) {
    const ConvKernel *kernel = state;
    const OrtApi *api = kernel->api;
    const OrtValue *input, *weights, *bias;
    CHECK(api->KernelContext_GetInput(context, 0, &input));
    CHECK(api->KernelContext_GetInput(context, 1, &weights));
    CHECK(api->KernelContext_GetInput(context, 2, &bias));
    if (!input || !weights || !bias)
        return api->CreateStatus(ORT_INVALID_ARGUMENT, "Audio8 convolution input missing");

    int64_t x[3], w[3], b[1];
    CHECK(dimensions(api, input, x, 3));
    CHECK(dimensions(api, weights, w, 3));
    CHECK(dimensions(api, bias, b, 1));
    const int64_t stride = kernel->stride;
    const int transposed = stride > 1;
    const int64_t rows = transposed ? w[1] : w[0];
    const int64_t in_channels = transposed ? w[0] : w[1];
    if (x[0] < 1 || x[0] > INT_MAX || x[1] < 1 || x[1] > INT_MAX / 16 ||
        x[2] < 1 || x[2] > INT_MAX || x[1] != in_channels || rows < 1 ||
        rows > INT_MAX / 16 || b[0] != rows ||
        (transposed ? (kernel->dilation != 1 || (w[2] != stride && w[2] != 2 * stride))
                    : (w[2] != 1 && w[2] != 7)))
        return api->CreateStatus(ORT_INVALID_ARGUMENT, "Unexpected Audio8 convolution shape");
    const int64_t output_width = transposed ? (x[2] - 1) * stride + w[2]
        : x[2] - kernel->dilation * (w[2] - 1);
    if (output_width <= 0 || output_width > INT_MAX)
        return api->CreateStatus(ORT_INVALID_ARGUMENT, "Unexpected Audio8 convolution length");

    const void *input_data, *weight_data, *bias_data;
    CHECK(api->GetTensorData(input, &input_data));
    CHECK(api->GetTensorData(weights, &weight_data));
    CHECK(api->GetTensorData(bias, &bias_data));
    int64_t output_dims[] = {x[0], rows, output_width};
    OrtValue *output;
    CHECK(api->KernelContext_GetOutput(context, 0, output_dims, 3, &output));
    void *output_data;
    CHECK(api->GetTensorMutableData(output, &output_data));

    if (transposed) {
        CHECK(transpose_conv(api, input_data, weight_data, output_data, (int)x[0],
                             (int)x[1], (int)x[2], (int)rows, (int)w[2],
                             (int)stride, (int)output_width));
        const float *offsets = bias_data;
        float *target = output_data;
        for (int batch = 0; batch < x[0]; ++batch) {
            for (int row = 0; row < rows; ++row, target += output_width)
                vDSP_vsadd(target, 1, offsets + row, target, 1, output_width);
        }
        return NULL;
    }

    const int channels = (int)x[1], width = (int)x[2], count = (int)w[0];
    const int window = (int)w[2], dilation = (int)kernel->dilation, expected = (int)output_width;
    const int depth = channels * window;
    const int tile = expected < 2048 ? expected : 2048;
    float *columns = window == 1 ? NULL : malloc((size_t)tile * depth * sizeof(float));
    if (window > 1 && !columns)
        return api->CreateStatus(ORT_FAIL, "Could not allocate Audio8 convolution workspace");
    const float *input_base = input_data;
    float *output_base = output_data;
    const float *offsets = bias_data;

    for (int batch = 0; batch < x[0]; ++batch) {
        const float *source = input_base + (size_t)batch * channels * width;
        float *target = output_base + (size_t)batch * count * expected;
        if (window == 1) {
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, count, expected, channels,
                        1, weight_data, channels, source, width, 0, target, expected);
        } else {
            for (int first = 0; first < expected; first += tile) {
                const int span = expected - first < tile ? expected - first : tile;
                for (int channel = 0; channel < channels; ++channel) {
                    for (int tap = 0; tap < window; ++tap) {
                        memcpy(columns + (size_t)(channel * window + tap) * span,
                               source + (size_t)channel * width + first + tap * dilation,
                               (size_t)span * sizeof(float));
                    }
                }
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, count, span, depth,
                            1, weight_data, depth, columns, span, 0, target + first, expected);
            }
        }
        for (int row = 0; row < count; ++row) {
            float *line = target + (size_t)row * expected;
            vDSP_vsadd(line, 1, offsets + row, line, 1, expected);
        }
    }
    free(columns);
    return NULL;
}

static const OrtCustomOp op = {
    .version = ORT_API_VERSION,
    .GetName = op_name,
    .GetExecutionProviderType = op_provider,
    .GetInputTypeCount = input_count,
    .GetInputType = value_type,
    .GetOutputTypeCount = output_count,
    .GetOutputType = value_type,
    .GetInputCharacteristic = required,
    .GetOutputCharacteristic = required,
    .GetInputMemoryType = memory_type,
    .KernelDestroy = free,
    .CreateKernelV2 = create_kernel,
    .KernelComputeV2 = compute,
    .GetStartVersion = version,
    .GetEndVersion = version,
};

OrtStatus *ORT_API_CALL RegisterCustomOps(OrtSessionOptions *options, const OrtApiBase *base) {
    const OrtApi *api = base->GetApi(ORT_API_VERSION);
    if (!api) return base->GetApi(1)->CreateStatus(ORT_FAIL, "Audio8 requires ONNX Runtime 1.23");
    static OrtCustomOpDomain *domain;
    if (!domain) {
        OrtCustomOpDomain *created;
        CHECK(api->CreateCustomOpDomain("com.maomijian.audio8", &created));
        OrtStatus *status = api->CustomOpDomain_Add(created, &op);
        if (status) {
            api->ReleaseCustomOpDomain(created);
            return status;
        }
        domain = created;
    }
    return api->AddCustomOpDomain(options, domain);
}
