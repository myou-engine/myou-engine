'use strict'

var webpack = require('webpack');
module.exports = {
    context: __dirname,
    entry: [
        __dirname + '/pack.coffee',
    ],
    stats: {
        colors: true,
        reasons: true
    },
    module: {
        loaders: [
            {
                test: /\.coffee$/,
                loaders: [
                    'coffee-loader',
                ]
            },
        ]
    },
    output: {
        path: __dirname + '/dist/',
        filename: 'myou.js',
        // export commonjs2 and var at the same time
        library: 'MyouEngine = module.exports',
    },
    plugins: [
        new webpack.BannerPlugin([
            '"use strict";',
            '/**',
            ' * Myou Engine',
            ' *',
            ' * Copyright (c) 2016 by Alberto Torres Ruiz <kungfoobar@gmail.com>',
            ' * Copyright (c) 2016 by Julio Manuel López Tercero <julio@pixelements.net>',
            ' *',
            ' * Permission is hereby granted, free of charge, to any person obtaining a copy',
            ' * of this software and associated documentation files (the "Software"), to deal',
            ' * in the Software without restriction, including without limitation the rights',
            ' * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell',
            ' * copies of the Software, and to permit persons to whom the Software is',
            ' * furnished to do so, subject to the following conditions:',
            ' *',
            ' * The above copyright notice and this permission notice shall be included in',
            ' * all copies or substantial portions of the Software.',
            ' *',
            ' * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR',
            ' * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,',
            ' * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE',
            ' * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER',
            ' * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,',
            ' * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE',
            ' * SOFTWARE.',
            ' */'
        ].join('\n'), {
            raw: true
        }),
    ],
    resolve: {
        extensions: ['', '.webpack.js', '.web.js', '.js', '.coffee', '.json']
    },
}
